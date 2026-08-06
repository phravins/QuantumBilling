defmodule QuantumBilling.Invoices do
  @moduledoc """
  GST invoices.

  ## Invoice numbering

  The number is not decorative — GST requires a sequential series — so it is
  consumed from `organization_settings.invoice_next_number` inside the same
  transaction that inserts the invoice, and the counter is advanced in that
  same transaction. Two people saving at the same moment therefore cannot be
  handed the same number, and a unique index on `invoice_number` makes any
  remaining slip loud rather than silent.

  A Draft consumes a number too. There is no separate "finalise" step in this
  flow to defer consumption to, and a gap-free series matters more than
  reserving numbers for finished invoices.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias QuantumBilling.Events
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Layout

  @doc """
  Every invoice, newest first, shaped for the list page.

  The list renders `number`, `client`, `invoice_date`, `due_date`, `amount`,
  `status` and sorts on `seq`, so those are what this returns — the page itself
  needs no change to start showing real rows. The Dashboard's recent-invoices
  table reads the same shape and additionally shows `gstin` and `tax_type`.
  """
  def list_invoices do
    Repo.all(from i in Invoice, order_by: [desc: i.invoice_date, desc: i.id])
    |> Enum.map(&to_row/1)
  end

  defp to_row(%Invoice{} = invoice) do
    %{
      id: invoice.id,
      seq: invoice.id,
      number: invoice.invoice_number,
      client: invoice.client_name,
      gstin: invoice.client_gstin,
      invoice_date: invoice.invoice_date,
      due_date: invoice.due_date || invoice.invoice_date,
      amount: invoice.grand_total,
      # Which taxes the supply attracts, not the document type: an intra-state
      # supply splits into CGST and SGST, an inter-state one is a single IGST.
      tax_type: if(Invoice.intra_state?(invoice), do: "CGST + SGST", else: "IGST"),
      status: invoice.status
    }
  end

  @doc """
  Fetches an invoice with its line items, raising when it does not exist.
  """
  def get_invoice!(id) do
    Invoice
    |> Repo.get!(id)
    |> Repo.preload(items: from(i in QuantumBilling.Invoices.InvoiceItem, order_by: i.position))
  end

  @doc """
  Fetches an invoice with its line items, or `nil`.
  """
  def get_invoice(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        Invoice
        |> Repo.get(int_id)
        |> case do
          nil ->
            nil

          invoice ->
            Repo.preload(invoice,
              items: from(i in QuantumBilling.Invoices.InvoiceItem, order_by: i.position)
            )
        end

      _not_an_id ->
        nil
    end
  end

  @doc """
  Builds a changeset for the invoice form.
  """
  def change_invoice(%Invoice{} = invoice \\ %Invoice{}, attrs \\ %{}) do
    Invoice.changeset(invoice, attrs)
  end

  @doc """
  Creates an invoice, assigning it the next number in the series.

  The number is read and advanced in the same transaction as the insert, so
  concurrent saves cannot collide.
  """
  def create_invoice(attrs) do
    # Outside the transaction on purpose: the lock below can only lock a row
    # that already exists, and racing to create it *inside* the transaction is
    # what deadlocks concurrent callers.
    organization = Settings.ensure_organization() || %Organization{}

    # Read-only, and outside the transaction. Issuing an invoice must not create
    # a design: two saves racing to insert the first one contend on the partial
    # unique index over `is_default` and deadlock each other. Seeding belongs to
    # the screens that are about to write anyway — the settings panel and the
    # design pad.
    template = resolve_template(attrs)

    Multi.new()
    # Locked for update, so two transactions cannot read the same next number
    # before either has written its increment.
    |> Multi.run(:organization, fn repo, _changes ->
      case repo.one(from o in Organization, order_by: [asc: o.id], limit: 1, lock: "FOR UPDATE") do
        nil -> {:ok, %Organization{}}
        organization -> {:ok, organization}
      end
    end)
    |> Multi.insert(:invoice, fn %{organization: locked} ->
      attrs
      |> with_number(locked)
      |> with_company_snapshot(locked)
      |> with_layout_snapshot(template, organization)
      |> then(&Invoice.changeset(%Invoice{}, &1))
    end)
    |> Multi.run(:advance_number, fn repo, %{organization: organization} ->
      # A brand new installation has no settings row yet. Insert one rather
      # than skipping the increment: without somewhere durable to keep the
      # counter, every invoice would be handed number 1 and the second would
      # die on the unique index.
      organization
      |> Ecto.Changeset.change(%{
        invoice_next_number: (organization.invoice_next_number || 1) + 1
      })
      |> repo.insert_or_update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invoice: invoice}} ->
        # The list, Dashboard and Reports pages already subscribe to this from
        # the realtime work, so they update without any further wiring.
        broadcast_change(invoice, :invoice_changed)
        {:ok, Repo.preload(invoice, :items)}

      {:error, :invoice, changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Updates an invoice in place.

  Neither the number nor the company block is touched. The number belongs to the
  series and reassigning it would break the sequence; the company block is a
  snapshot of who issued the invoice at the time, and refreshing it here would
  quietly rewrite history whenever Settings changed. Items are replaced wholesale
  — `has_many :items, on_replace: :delete` is what makes a removed row actually
  go.

  The layout snapshot is refreshed only while the invoice is still a draft. A
  draft has not been sent to anybody, so re-taking it is how a template change
  reaches an invoice still being written; once it has left the building, the
  document it was is the document it stays.
  """
  def update_invoice(%Invoice{} = invoice, attrs) do
    invoice
    |> Repo.preload(:items)
    |> Invoice.changeset(refresh_layout(attrs, invoice))
    |> Repo.update()
    |> case do
      {:ok, invoice} ->
        broadcast_change(invoice, :invoice_changed)
        {:ok, Repo.preload(invoice, :items, force: true)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes an invoice and its line items.

  The number is not returned to the series: `invoice_next_number` only ever goes
  forward, so a deleted invoice leaves a gap rather than letting the next save
  reuse a number that has already been out in the world.
  """
  def delete_invoice(%Invoice{} = invoice) do
    case Repo.delete(invoice) do
      {:ok, invoice} ->
        broadcast_change(invoice, :invoice_changed)
        {:ok, invoice}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp with_number(attrs, organization) do
    put_attr(attrs, "invoice_number", Settings.next_invoice_number(organization))
  end

  defp with_company_snapshot(attrs, organization) do
    attrs
    |> put_attr("company_name", organization.company_name)
    |> put_attr("company_address", organization.address)
    |> put_attr("company_gstin", organization.gstin)
    |> put_attr("company_state", organization.state)
  end

  # The caller may name a template; without one it gets whichever is default at
  # the moment of issue. Read-only by design — see `create_invoice/1`.
  defp resolve_template(attrs) do
    case template_id_from(attrs) do
      nil -> Templates.default_template()
      id -> Templates.get_template(id) || Templates.default_template()
    end
  end

  # Freezes the design onto the invoice.
  defp with_layout_snapshot(attrs, %{id: id, layout_xml: xml}, _organization) do
    attrs |> put_attr("template_id", id) |> put_attr("layout_xml", xml)
  end

  # No design exists yet — this installation has never opened the design pad.
  # The layout is still frozen, so an invoice issued now keeps its document even
  # if a design is created and edited afterwards. Freezing the XML rather than
  # creating a template row is what keeps issuing an invoice a read as far as
  # designs are concerned.
  defp with_layout_snapshot(attrs, nil, _organization) do
    xml = Catalog.classic() |> Layout.to_xml()

    attrs |> put_attr("template_id", nil) |> put_attr("layout_xml", xml)
  end

  # Only while it is a draft, and judged by the *stored* status rather than the
  # incoming params: reading it from params would let a save that also flips the
  # status re-freeze a document that has already gone out.
  defp refresh_layout(attrs, %Invoice{status: "Draft"}) do
    with_layout_snapshot(attrs, resolve_template(attrs), Settings.get_organization())
  end

  defp refresh_layout(attrs, %Invoice{}), do: drop_layout_attrs(attrs)

  # A non-draft must not have its snapshot rewritten even by a caller that sends
  # the fields explicitly.
  defp drop_layout_attrs(attrs) do
    Enum.reduce(["layout_xml", "template_id"], attrs, fn key, acc ->
      Map.drop(acc, [key, String.to_existing_atom(key)])
    end)
  end

  defp template_id_from(attrs) do
    case Map.get(attrs, "template_id", Map.get(attrs, :template_id)) do
      nil ->
        nil

      "" ->
        nil

      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {n, ""} -> n
          _other -> nil
        end
    end
  end

  # The form submits string-keyed params; tests and other callers may pass
  # atoms. Writing in whichever style the map already uses keeps `cast/3` from
  # seeing a mix, which it rejects.
  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_atom/1) do
      Map.put(attrs, String.to_existing_atom(key), value)
    else
      Map.put(attrs, key, value)
    end
  end

  @doc """
  Subscribes the caller to invoice changes.
  """
  def subscribe, do: Events.subscribe(Events.invoices_topic())

  @doc """
  Announces an invoice change to every listening page.
  """
  def broadcast_change(invoice, event \\ :invoice_changed) do
    Events.broadcast(Events.invoices_topic(), {event, invoice})
  end

  defdelegate invoice_types(), to: Invoice
  defdelegate payment_terms(), to: Invoice
  defdelegate statuses(), to: Invoice
end
