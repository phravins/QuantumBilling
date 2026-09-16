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
  alias QuantumBilling.Webhooks
  alias QuantumBilling.Workers.EInvoiceWorker
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Layout

  # The list page's sortable columns, and the database column each one means.
  # An allowlist rather than a lookup: the sort field arrives from a click in
  # the browser, and turning user input into a column name — or into an atom —
  # is how an ordering control becomes an injection point.
  @sortable %{
    seq: :id,
    number: :invoice_number,
    client: :client_name,
    invoice_date: :invoice_date,
    due_date: :due_date,
    amount: :grand_total,
    status: :status
  }

  @default_per_page 10
  @max_per_page 200

  @doc """
  Every invoice, newest first, shaped for the list page.

  Unbounded, so it is for callers that genuinely want all of them — a backup, a
  test. Anything user-facing should use `page/1`, which reads one screen.
  """
  def list_invoices do
    Repo.all(from i in Invoice, order_by: [desc: i.invoice_date, desc: i.id])
    |> Enum.map(&to_row/1)
  end

  @doc """
  One page of invoices, filtered, sorted and counted by the database.

  Returns `%{rows:, total:, page:, per_page:, total_pages:}`.

  The searching, filtering, sorting and slicing used to happen in Elixir over
  every invoice in the system, reloaded into the LiveView's memory on every
  change anywhere in the application. At a few hundred invoices that is
  invisible; at a hundred thousand it is a copy of the invoice table per open
  browser tab. The database does all four now, and only the rows on screen are
  ever loaded.

  ## Options

    * `:search` — matches the invoice number, client name or GSTIN
    * `:status` — exact status, or `"All Status"`
    * `:sort_field` / `:sort_dir` — a key of the sortable allowlist, `:asc` or `:desc`
    * `:page` / `:per_page`
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp(1, @max_per_page)

    query =
      Invoice
      |> search_where(Keyword.get(opts, :search))
      |> status_where(Keyword.get(opts, :status))

    total = Repo.aggregate(query, :count, :id)
    total_pages = max(ceil(total / per_page), 1)
    page = opts |> Keyword.get(:page, 1) |> clamp(1, total_pages)

    rows =
      query
      |> order(Keyword.get(opts, :sort_field, :invoice_date), Keyword.get(opts, :sort_dir, :desc))
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()
      |> Enum.map(&to_row/1)

    %{rows: rows, total: total, page: page, per_page: per_page, total_pages: total_pages}
  end

  @doc """
  The most recently issued invoices, as list rows.

  What the dashboard's "recent invoices" table wants, expressed as a query
  rather than as the first few of everything.
  """
  def recent_invoices(limit \\ 5) do
    Invoice
    |> order_by([i], desc: i.invoice_date, desc: i.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc """
  Counts and money totals across every invoice, computed by the database.

  Returns `%{count:, revenue:, tax:, outstanding:, paid_count:}`, where
  `revenue` is the value of everything issued and `outstanding` is the part of
  it that is neither paid nor cancelled.
  """
  def totals do
    Invoice
    |> select([i], %{
      count: count(i.id),
      revenue: coalesce(sum(i.grand_total), 0),
      tax:
        coalesce(
          sum(
            coalesce(i.cgst_amount, 0) + coalesce(i.sgst_amount, 0) +
              coalesce(i.igst_amount, 0) + coalesce(i.cess_amount, 0)
          ),
          0
        ),
      outstanding:
        coalesce(
          sum(
            fragment(
              "CASE WHEN ? IN ('Paid', 'Cancelled') THEN 0 ELSE COALESCE(?, 0) END",
              i.status,
              i.grand_total
            )
          ),
          0
        ),
      paid_count: coalesce(count(i.id) |> filter(i.status == "Paid"), 0)
    })
    |> Repo.one()
    |> case do
      nil -> %{count: 0, revenue: 0, tax: 0, outstanding: 0, paid_count: 0}
      totals -> totals
    end
  end

  @doc """
  Totals for the invoices dated within `month`.

  What the dashboard's "this month" cards are actually about: the tax charged
  on what was billed this month, which is the figure that becomes a GSTR-3B
  liability. They used to be hardcoded zeros.
  """
  def month_totals(date \\ Date.utc_today()) do
    from = Date.beginning_of_month(date)
    to = Date.end_of_month(date)

    Invoice
    |> where([i], i.invoice_date >= ^from and i.invoice_date <= ^to)
    |> where([i], i.status != "Cancelled")
    |> select([i], %{
      count: count(i.id),
      taxable_value: coalesce(sum(i.taxable_value), 0),
      cgst: coalesce(sum(i.cgst_amount), 0),
      sgst: coalesce(sum(i.sgst_amount), 0),
      igst: coalesce(sum(i.igst_amount), 0),
      cess: coalesce(sum(i.cess_amount), 0),
      invoice_value: coalesce(sum(i.grand_total), 0)
    })
    |> Repo.one()
    |> case do
      nil ->
        %{
          count: 0,
          taxable_value: 0,
          cgst: 0,
          sgst: 0,
          igst: 0,
          cess: 0,
          invoice_value: 0,
          tax: 0
        }

      totals ->
        Map.put(totals, :tax, totals.cgst + totals.sgst + totals.igst + totals.cess)
    end
  end

  @doc """
  The CGST+SGST and IGST charged per month over the last `count` months,
  oldest first, as `[%{label, cgst_sgst, igst}]`.

  Months with no invoices are included as zeros: a gap in a bar chart has to
  read as "nothing was billed", not as a month that does not exist.
  """
  def monthly_tax_split(count \\ 6, today \\ Date.utc_today()) do
    first = today |> Date.beginning_of_month() |> shift_months(-(count - 1))
    last = Date.end_of_month(today)

    billed =
      Invoice
      |> where([i], i.invoice_date >= ^first and i.invoice_date <= ^last)
      |> where([i], i.status != "Cancelled")
      |> group_by([i], fragment("date_trunc('month', ?)", i.invoice_date))
      |> select([i], %{
        month: fragment("date_trunc('month', ?)", i.invoice_date),
        cgst_sgst: coalesce(sum(coalesce(i.cgst_amount, 0) + coalesce(i.sgst_amount, 0)), 0),
        igst: coalesce(sum(i.igst_amount), 0)
      })
      |> Repo.all()
      |> Map.new(fn row -> {month_key(row.month), row} end)

    for offset <- 0..(count - 1) do
      month = shift_months(first, offset)
      row = Map.get(billed, {month.year, month.month})

      %{
        label: Calendar.strftime(month, "%b"),
        cgst_sgst: (row && row.cgst_sgst) || 0,
        igst: (row && row.igst) || 0
      }
    end
  end

  defp month_key(%Date{} = date), do: {date.year, date.month}
  defp month_key(%NaiveDateTime{} = naive), do: {naive.year, naive.month}
  defp month_key(%DateTime{} = datetime), do: {datetime.year, datetime.month}

  defp shift_months(%Date{} = date, count) do
    total = date.year * 12 + (date.month - 1) + count

    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end

  @doc "How many invoices are in each status."
  def status_counts do
    Invoice
    |> group_by([i], i.status)
    |> select([i], {i.status, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp search_where(query, blank) when blank in [nil, ""], do: query

  defp search_where(query, search) do
    pattern = "%" <> String.trim(search) <> "%"

    where(
      query,
      [i],
      ilike(i.invoice_number, ^pattern) or ilike(i.client_name, ^pattern) or
        ilike(i.client_gstin, ^pattern)
    )
  end

  defp status_where(query, status) when status in [nil, "", "All Status"], do: query
  defp status_where(query, status), do: where(query, [i], i.status == ^status)

  defp order(query, field, direction) do
    column = Map.get(@sortable, field, :invoice_date)
    direction = if direction == :asc, do: :asc, else: :desc

    # The id is the tie-breaker. Without it, two invoices sharing a date can
    # swap places between one page and the next, which shows a row twice and
    # hides another.
    order_by(query, [i], [{^direction, field(i, ^column)}, {^direction, i.id}])
  end

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  @doc "The columns the list page may sort on."
  def sortable_fields, do: Map.keys(@sortable)

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
  Fetches an invoice by its unique invoice_number.
  """
  def get_invoice_by_number(invoice_number) when is_binary(invoice_number) do
    Invoice
    |> Repo.get_by(invoice_number: invoice_number)
    |> case do
      nil ->
        nil

      invoice ->
        Repo.preload(invoice,
          items: from(i in QuantumBilling.Invoices.InvoiceItem, order_by: i.position)
        )
    end
  end

  @doc """
  Fetches an invoice by its unique public_token for the public portal.
  """
  def get_invoice_by_token(token) when is_binary(token) do
    Invoice
    |> Repo.get_by(public_token: token)
    |> case do
      nil ->
        nil

      invoice ->
        Repo.preload(invoice,
          items: from(i in QuantumBilling.Invoices.InvoiceItem, order_by: i.position)
        )
    end
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

        # And anything the business has pointed at its own webhook endpoint —
        # an accounting system, an internal dashboard — hears about it too.
        Webhooks.dispatch("invoice.created", %{
          invoice_id: invoice.id,
          invoice_number: invoice.invoice_number,
          client_name: invoice.client_name,
          grand_total: invoice.grand_total,
          invoice_date: to_string(invoice.invoice_date)
        })

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
  Queues registration of an invoice with the IRP.

  Returns `{:ok, :queued}`, `{:ok, :already_registered}` for an invoice that
  already carries an IRN, or `{:error, reason}`.

  The invoice is moved to `"Pending E-Invoice"` immediately so the page shows
  what is happening; the job replaces that with the real outcome. Registering
  inline used to hold the request open for however long the government portal
  took, and left `"E-Invoice Failed"` behind with nothing that would ever try
  again.
  """
  def queue_einvoice(%Invoice{irn: irn}) when is_binary(irn) and irn != "" do
    {:ok, :already_registered}
  end

  def queue_einvoice(%Invoice{} = invoice) do
    case %{"invoice_id" => invoice.id} |> EInvoiceWorker.new() |> Oban.insert() do
      {:ok, _job} ->
        # Deliberately not through `update_invoice/2`: this is a status stamp,
        # not an edit, and it must not re-take the layout snapshot.
        invoice
        |> Ecto.Changeset.change(%{status: "Pending E-Invoice"})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            broadcast_change(updated, :invoice_changed)
            {:ok, :queued}

          {:error, changeset} ->
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates an E-Invoice (IRN) for the given invoice via the IRP API or sandbox emulator.
  Updates the invoice with the returned IRN, Ack Details, and Signed QR code, transitioning its
  status to "E-Invoice Generated".

  Called by `QuantumBilling.Workers.EInvoiceWorker`; use `queue_einvoice/1`
  from anything a person is waiting on.
  """
  def generate_einvoice(%Invoice{} = invoice) do
    invoice = Repo.preload(invoice, :items)

    case QuantumBilling.EInvoice.IRPClient.generate_irn(invoice) do
      {:ok,
       %{irn: irn, ack_no: ack_no, ack_date: ack_date, signed_qr_code: qr, signed_invoice: jwt}} ->
        update_attrs = %{
          irn: irn,
          ack_number: ack_no,
          ack_date: ack_date,
          signed_qr_code: qr,
          signed_invoice: jwt,
          status: "E-Invoice Generated"
        }

        update_invoice(invoice, update_attrs)

      {:error, reason} ->
        _ = update_invoice(invoice, %{status: "E-Invoice Failed"})
        {:error, reason}
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
