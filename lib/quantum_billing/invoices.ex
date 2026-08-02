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
    Settings.ensure_organization()

    Multi.new()
    # Locked for update, so two transactions cannot read the same next number
    # before either has written its increment.
    |> Multi.run(:organization, fn repo, _changes ->
      case repo.one(from o in Organization, order_by: [asc: o.id], limit: 1, lock: "FOR UPDATE") do
        nil -> {:ok, %Organization{}}
        organization -> {:ok, organization}
      end
    end)
    |> Multi.insert(:invoice, fn %{organization: organization} ->
      attrs
      |> with_number(organization)
      |> with_company_snapshot(organization)
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
  """
  def update_invoice(%Invoice{} = invoice, attrs) do
    invoice
    |> Repo.preload(:items)
    |> Invoice.changeset(attrs)
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
