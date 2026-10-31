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

  ## Deleting

  `delete_invoice/2` moves an invoice to the Bin; `restore_invoice/2` brings it
  back and `purge_invoice/2` removes it for good. Every read in this module
  goes through `Invoice.kept/1`, so a binned invoice is absent from the lists,
  the totals and the lookups alike — the only ways to reach one are
  `list_deleted_invoices/0`, `get_deleted_invoice/1` and the payment webhook's
  `get_invoice_by_number/2`, which asks for it by name.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias QuantumBilling.Audit
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Events
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Notifications
  alias QuantumBilling.Paging
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Templates
  alias QuantumBilling.Webhooks
  alias QuantumBilling.Workers.EInvoiceWorker
  alias QuantumBillingWeb.Format
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Layout

  # Allowlisted: the sort field comes from the browser.
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
    Repo.all(from i in Invoice.kept(), order_by: [desc: i.invoice_date, desc: i.id])
    |> Enum.map(&to_row/1)
  end

  @doc """
  One page of invoices, filtered and sorted by the database.

  Returns `%{rows:, page:, per_page:, has_next?:}`, plus `:total` and
  `:total_pages` with `count: true`. See `QuantumBilling.Paging` on why the
  rows are not counted otherwise.

  The searching, filtering, sorting and slicing used to happen in Elixir over
  every invoice in the system, reloaded into the LiveView's memory on every
  change anywhere in the application. At a few hundred invoices that is
  invisible; at a hundred thousand it is a copy of the invoice table per open
  browser tab. The database does all four now, and only the rows on screen are
  ever loaded.

  ## Options

    * `:search` — matches the invoice number, client name or GSTIN
    * `:status` — exact status, or `"All Status"`
    * `:client` — a `%Clients.Client{}`, narrowing to that client's invoices
    * `:sort_field` / `:sort_dir` — a key of the sortable allowlist, `:asc` or `:desc`
    * `:page` / `:per_page`
    * `:count` — also count the matching invoices
    * `:keyset` / `:before_id` — newest-created first, below `:before_id`,
      instead of numbered pages; see `QuantumBilling.Paging.keyset/3`
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp(1, @max_per_page)
    sort_field = Keyword.get(opts, :sort_field, :invoice_date)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)

    query =
      Invoice.kept()
      |> search_where(Keyword.get(opts, :search))
      |> status_where(Keyword.get(opts, :status))
      |> client_where(Keyword.get(opts, :client))

    result =
      if Keyword.get(opts, :keyset, false) do
        Paging.keyset(query, Keyword.get(opts, :before_id), per_page)
      else
        Paging.page(query, &order(&1, sort_field, sort_dir),
          page: Keyword.get(opts, :page, 1),
          per_page: per_page,
          count: Keyword.get(opts, :count, false)
        )
      end

    shape(result, Keyword.get(opts, :records, false))
  end

  # `records: true` hands back the invoices themselves, for callers that shape
  # their own output — the API. Same query either way, so what is visible (the
  # Bin excluded, the filters applied) is decided in exactly one place.
  defp shape(result, true), do: result
  defp shape(result, _rows), do: %{result | rows: Enum.map(result.rows, &to_row/1)}

  @doc """
  The most recently issued invoices, as list rows.

  What the dashboard's "recent invoices" table wants, expressed as a query
  rather than as the first few of everything.
  """
  def recent_invoices(limit \\ 5) do
    Invoice.kept()
    |> order_by([i], desc: i.invoice_date, desc: i.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc """
  Invoices that could still be given an e-way bill, newest first.

  What the "Generate New E-Way Bill" page loads a consignment from: a bill is
  raised against a document that exists, so the form picks the document rather
  than inventing one. Cancelled invoices and invoices that already carry a live
  bill are left out — the portal issues one live bill per document.

  A *cancelled* bill does not exclude its invoice, because Rule 138(9) exists
  precisely so a fresh bill can be raised against the same document.

  No threshold is applied here: a bill below the threshold is optional, not
  forbidden, and a picker that hid those invoices would make a legal document
  impossible to raise. `count_requiring_e_way_bill/0` is the threshold's job.
  """
  def awaiting_e_way_bill(limit \\ 50) do
    Invoice.kept()
    |> where([i], i.status != "Cancelled")
    |> where(
      [i],
      not exists(
        from b in QuantumBilling.EWayBills.EWayBill,
          where:
            b.invoice_id == parent_as(:invoice).id and b.status != "Cancelled" and
              is_nil(b.deleted_at),
          select: 1
      )
    )
    |> from(as: :invoice)
    |> order_by([i], desc: i.invoice_date, desc: i.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  How many invoices are over the configured consignment threshold and still
  have no live e-way bill.

  `organization_settings.ewb_threshold_value` is what Rule 138(1) means by "of
  consignment value exceeding fifty thousand rupees" — the setting was saved
  by the settings form and read by nothing, so a business that raised it to
  ₹1,00,000 saw no difference anywhere.
  """
  def count_requiring_e_way_bill do
    threshold = Settings.get_organization().ewb_threshold_value || 5_000_000

    Invoice.kept()
    |> from(as: :invoice)
    |> where([i], i.status != "Cancelled" and i.grand_total > ^threshold)
    |> where(
      [i],
      not exists(
        from b in QuantumBilling.EWayBills.EWayBill,
          where:
            b.invoice_id == parent_as(:invoice).id and b.status != "Cancelled" and
              is_nil(b.deleted_at),
          select: 1
      )
    )
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Counts and money totals across every invoice, computed by the database.

  Returns `%{count:, revenue:, tax:, outstanding:, paid_count:}`, where
  `revenue` is the value of everything issued and `outstanding` is the part of
  it that is neither paid nor cancelled, **net of the notes raised against
  it** — a credit note reduces what the customer owes and a debit note adds to
  it. Without that, an invoice credited in full still read as fully
  receivable, and the dashboard's figure was the one number in the application
  a business would act on.
  """
  def totals do
    invoices = invoice_totals()
    adjustments = note_adjustments()

    outstanding = max(invoices.outstanding - adjustments.credits + adjustments.debits, 0)

    %{invoices | outstanding: outstanding}
  end

  defp invoice_totals do
    Invoice.kept()
    |> select([i], %{
      count: count(i.id),
      revenue: type(coalesce(sum(i.grand_total), 0), :integer),
      tax:
        type(
          coalesce(
            sum(
              coalesce(i.cgst_amount, 0) + coalesce(i.sgst_amount, 0) +
                coalesce(i.igst_amount, 0) + coalesce(i.cess_amount, 0)
            ),
            0
          ),
          :integer
        ),
      outstanding:
        type(
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
          :integer
        ),
      paid_count: coalesce(count(i.id) |> filter(i.status == "Paid"), 0)
    })
    |> Repo.one()
    |> case do
      nil -> %{count: 0, revenue: 0, tax: 0, outstanding: 0, paid_count: 0}
      totals -> totals
    end
  end

  # Notes against invoices still owed; a paid or cancelled invoice has nothing left to reduce.
  defp note_adjustments do
    totals =
      CreditNote
      |> join(:inner, [n], i in Invoice, on: i.id == n.invoice_id)
      |> where([n], n.status != "Cancelled")
      |> where([_n, i], i.status not in ["Paid", "Cancelled"])
      |> where([_n, i], is_nil(i.deleted_at))
      |> select([n], %{
        credits:
          type(coalesce(sum(n.grand_total) |> filter(n.note_type == "Credit"), 0), :integer),
        debits: type(coalesce(sum(n.grand_total) |> filter(n.note_type != "Credit"), 0), :integer)
      })
      |> Repo.one()

    case totals do
      nil -> %{credits: 0, debits: 0}
      totals -> totals
    end
  end

  @doc """
  What each client still owes, as a query of `%{client_id:, outstanding:}`.

  The same rule as `totals/0`, per client: the invoices that are neither paid
  nor cancelled, less the credit notes and plus the debit notes raised against
  them, floored at zero. Clients who owe nothing have no row.

  Pass `client_ids` to compute only those clients — one indexed lookup each,
  which is what a page of clients needs. Without it every client is grouped,
  which is only worth paying to sort the whole directory by what is owed.
  """
  def outstanding_by_client(client_ids \\ nil) do
    notes =
      from n in CreditNote,
        where: n.status != "Cancelled",
        group_by: n.invoice_id,
        select: %{
          invoice_id: n.invoice_id,
          net:
            sum(
              fragment(
                "CASE WHEN ? = 'Credit' THEN -? ELSE ? END",
                n.note_type,
                n.grand_total,
                n.grand_total
              )
            )
        }

    query =
      from i in Invoice.kept(),
        left_join: n in subquery(notes),
        on: n.invoice_id == i.id,
        where: not is_nil(i.client_id) and i.status not in ["Paid", "Cancelled"],
        group_by: i.client_id,
        select: %{
          client_id: i.client_id,
          outstanding:
            type(
              fragment(
                "GREATEST(SUM(COALESCE(?, 0) + COALESCE(?, 0)), 0)",
                i.grand_total,
                n.net
              ),
              :integer
            )
        }

    case client_ids do
      nil -> query
      ids -> where(query, [i], i.client_id in ^ids)
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

    Invoice.kept()
    |> where([i], i.invoice_date >= ^from and i.invoice_date <= ^to)
    |> where([i], i.status != "Cancelled")
    |> select([i], %{
      count: count(i.id),
      taxable_value: type(coalesce(sum(i.taxable_value), 0), :integer),
      cgst: type(coalesce(sum(i.cgst_amount), 0), :integer),
      sgst: type(coalesce(sum(i.sgst_amount), 0), :integer),
      igst: type(coalesce(sum(i.igst_amount), 0), :integer),
      cess: type(coalesce(sum(i.cess_amount), 0), :integer),
      invoice_value: type(coalesce(sum(i.grand_total), 0), :integer)
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
      Invoice.kept()
      |> where([i], i.invoice_date >= ^first and i.invoice_date <= ^last)
      |> where([i], i.status != "Cancelled")
      |> group_by([i], fragment("date_trunc('month', ?)", i.invoice_date))
      |> select([i], %{
        month: fragment("date_trunc('month', ?)", i.invoice_date),
        cgst_sgst:
          type(
            coalesce(sum(coalesce(i.cgst_amount, 0) + coalesce(i.sgst_amount, 0)), 0),
            :integer
          ),
        igst: type(coalesce(sum(i.igst_amount), 0), :integer)
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
    Invoice.kept()
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

  defp client_where(query, nil), do: query

  # Matched on client_id, or by name only for invoices without one.
  # Client names are not unique, so a linked invoice is never reattributed by name.
  defp client_where(query, %Client{id: id, name: name}) do
    where(query, [i], i.client_id == ^id or (is_nil(i.client_id) and i.client_name == ^name))
  end

  defp order(query, field, direction) do
    column = Map.get(@sortable, field, :invoice_date)
    direction = if direction == :asc, do: :asc, else: :desc

    # The id breaks ties so paging is stable.
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
      tax_type: if(Invoice.intra_state?(invoice), do: "CGST + SGST", else: "IGST"),
      status: invoice.status
    }
  end

  @doc """
  Fetches an invoice with its line items, raising when it does not exist.

  An invoice in the Bin does not exist as far as this is concerned.
  """
  def get_invoice!(id) do
    Invoice.kept()
    |> Repo.get!(id)
    |> with_items()
  end

  @doc """
  Fetches an invoice by its unique invoice_number.

  ## Options

    * `:include_binned` — also find an invoice that is in the Bin. For the
      payment webhook: money that arrives for a binned invoice has still
      arrived, and "no such invoice" would lose the record of it.
  """
  def get_invoice_by_number(invoice_number, opts \\ []) when is_binary(invoice_number) do
    query = if Keyword.get(opts, :include_binned, false), do: Invoice, else: Invoice.kept()

    query
    |> Repo.get_by(invoice_number: invoice_number)
    |> with_items()
  end

  @doc """
  Fetches an invoice by its unique public_token for the public portal.

  A binned invoice is not served: the link in a customer's inbox must stop
  showing a document the business has withdrawn.
  """
  def get_invoice_by_token(token) when is_binary(token) do
    Invoice.kept()
    |> Repo.get_by(public_token: token)
    |> with_items()
  end

  @doc """
  Fetches an invoice with its line items, or `nil`.
  """
  def get_invoice(id), do: fetch_by_id(Invoice.kept(), id)

  @doc """
  Fetches an invoice that is in the Bin, with its line items, or `nil`.
  """
  def get_deleted_invoice(id), do: fetch_by_id(Invoice.binned(), id)

  @doc """
  Every invoice in the Bin, most recently binned first.
  """
  def list_deleted_invoices do
    Repo.all(from i in Invoice.binned(), order_by: [desc: i.deleted_at, desc: i.id])
  end

  @doc "How many invoices are in the Bin."
  def count_deleted_invoices, do: Repo.aggregate(Invoice.binned(), :count, :id)

  defp fetch_by_id(query, id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} -> query |> Repo.get(int_id) |> with_items()
      _not_an_id -> nil
    end
  end

  defp with_items(nil), do: nil

  defp with_items(%Invoice{} = invoice) do
    Repo.preload(invoice,
      items: from(i in QuantumBilling.Invoices.InvoiceItem, order_by: i.position)
    )
  end

  @doc """
  Builds a changeset for the invoice form.
  """
  def change_invoice(%Invoice{} = invoice \\ %Invoice{}, attrs \\ %{}, trusted \\ %{}) do
    Invoice.changeset(invoice, attrs, trusted)
  end

  @doc """
  The client details an invoice records about whom it was issued to.

  A snapshot, copied onto the invoice rather than read live through the
  association: a GST invoice has to keep saying what it said when it was
  issued, whatever later happens to the client record.

  One function for both the invoice form and the API, so the two cannot
  disagree about what an invoice records — and so the API never takes a
  client's name, GSTIN or address from the request body, where a caller could
  put an invoice in one customer's name and another's GSTIN.
  """
  def client_snapshot(%QuantumBilling.Clients.Client{} = client) do
    %{
      "client_id" => client.id,
      "client_name" => client.name,
      "client_gstin" => client.gstin,
      # Not every client has a PAN typed in, but every GSTIN contains one.
      "client_pan" => present(client.pan) || QuantumBilling.GST.pan_from_gstin(client.gstin),
      "client_email" => client.email,
      "client_state" => client.billing_state,
      "client_billing_address" => billing_address(client),
      # Copied as their own fields as well as into the printed blob: the
      # e-invoice export needs the city and the PIN separately, and reading
      # them back out of the blob would mean parsing an address.
      "client_city" => client.billing_city,
      "client_pincode" => client.billing_pin
    }
  end

  defp billing_address(client) do
    [
      client.name,
      client.billing_line1,
      client.billing_line2,
      [client.billing_city, client.billing_state] |> Enum.reject(&is_nil/1) |> Enum.join(", "),
      client.billing_pin
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  @doc """
  Creates an invoice, assigning it the next number in the series.

  The number is read and advanced in the same transaction as the insert, so
  concurrent saves cannot collide.
  """
  def create_invoice(attrs) do
    # Outside the transaction: creating the row inside it deadlocks concurrent callers.
    organization = Settings.ensure_organization() || %Organization{}

    # Read-only: inserting the first design inside the transaction deadlocks concurrent saves.
    template = resolve_template(attrs)

    Multi.new()
    # Locked so two transactions cannot take the same number.
    |> Multi.run(:organization, fn repo, _changes ->
      case repo.one(from o in Organization, order_by: [asc: o.id], limit: 1, lock: "FOR UPDATE") do
        nil -> {:ok, %Organization{}}
        organization -> {:ok, organization}
      end
    end)
    |> Multi.insert(:invoice, fn %{organization: locked} ->
      trusted =
        %{}
        |> with_number(locked)
        |> with_company_snapshot(locked)
        |> with_layout_snapshot(template, organization)

      Invoice.changeset(%Invoice{}, attrs, trusted)
    end)
    |> Multi.run(:advance_number, fn repo, %{organization: organization} ->
      # A new installation has no settings row; without one every invoice would get number 1.
      organization
      |> Ecto.Changeset.change(%{
        invoice_next_number: (organization.invoice_next_number || 1) + 1
      })
      |> repo.insert_or_update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invoice: invoice}} ->
        broadcast_change(invoice, :invoice_changed)

        Webhooks.publish("invoice.created", invoice.id, %{
          invoice_id: invoice.id,
          invoice_number: invoice.invoice_number,
          client_name: invoice.client_name,
          # Whole rupees, as integrations have always received it.
          grand_total: div(invoice.grand_total || 0, 100),
          invoice_date: to_string(invoice.invoice_date)
        })

        # Result ignored: a failed notification must not undo the invoice.
        if organization.notify_invoice_created != false do
          Notifications.notify(%{
            kind: "invoice",
            title: "Invoice #{invoice.invoice_number} created",
            body: "#{invoice.client_name} · #{Format.rupees(invoice.grand_total)}",
            path: "/invoices/#{invoice.id}",
            dedupe_key: "invoice_created:#{invoice.id}"
          })
        end

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
    |> Invoice.changeset(drop_layout_unless_draft(attrs, invoice), refresh_layout(attrs, invoice))
    |> Repo.update()
    |> case do
      {:ok, invoice} ->
        broadcast_change(invoice, :invoice_changed)
        Webhooks.publish("invoice.updated", invoice.id)
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
        # Not via update_invoice/2: a status stamp must not re-take the layout snapshot.
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

  The invoice is validated against the e-invoice schema first. It was not
  before, so this path — the one that submits a document to the government and
  cannot be taken back — accepted invoices that the XML download refuses to
  even write to a file. An invoice with no line items got as far as the QR
  builder and crashed it.
  """
  def generate_einvoice(%Invoice{} = invoice) do
    invoice = Repo.preload(invoice, :items)

    with :ok <- QuantumBilling.EInvoice.validate(invoice, Settings.get_organization()) do
      submit_einvoice(invoice)
    else
      {:error, problems} when is_list(problems) ->
        mark_einvoice_failed(invoice)
        {:error, Enum.join(problems, " ")}
    end
  end

  defp submit_einvoice(%Invoice{} = invoice) do
    case QuantumBilling.EInvoice.IRPClient.generate_irn(invoice) do
      {:ok,
       %{
         irn: irn,
         ack_no: ack_no,
         ack_date: ack_date,
         signed_qr_code: qr,
         signed_invoice: jwt,
         mode: mode
       }} ->
        invoice
        |> Invoice.einvoice_changeset(%{
          irn: irn,
          ack_number: ack_no,
          ack_date: ack_date,
          signed_qr_code: qr,
          signed_invoice: jwt,
          irn_mode: mode,
          status: "E-Invoice Generated"
        })
        |> Repo.update()
        |> case do
          {:ok, invoice} ->
            broadcast_change(invoice, :invoice_changed)
            Webhooks.publish("invoice.e_invoice_generated", invoice.id)
            {:ok, Repo.preload(invoice, :items, force: true)}

          {:error, changeset} ->
            {:error, changeset}
        end

      {:error, reason} ->
        mark_einvoice_failed(invoice)
        {:error, reason}
    end
  end

  # Directly, like the other status stamps: status is not a form field.
  defp mark_einvoice_failed(invoice) do
    with {:ok, failed} <- Repo.update(Ecto.Changeset.change(invoice, status: "E-Invoice Failed")) do
      broadcast_change(failed, :invoice_changed)
      Webhooks.publish("invoice.e_invoice_failed", failed.id)
    end
  end

  @doc """
  Cancels an invoice: it keeps its number, leaves GSTR-1, and can no longer be
  paid.

  Refused, with the reason, when cancelling here would not be the whole story:

    * `:already_cancelled`;
    * `:paid` — money has moved; that needs a credit note, not a cancellation;
    * `:irn_registered` — a live IRN has to be cancelled on the IRP, which this
      application does not do;
    * `:live_e_way_bill` — the goods are on a live e-way bill, which has to be
      cancelled first.

  `opts` takes `:user_id`, `:api_key_id` and `:ip_address` for the audit entry.
  """
  def cancel_invoice(%Invoice{} = invoice, reason, opts \\ []) when is_binary(reason) do
    cond do
      invoice.status == "Cancelled" ->
        {:error, :already_cancelled}

      invoice.status == "Paid" ->
        {:error, :paid}

      is_binary(invoice.irn) and not Invoice.demo_irn?(invoice) ->
        {:error, :irn_registered}

      QuantumBilling.EWayBills.live_bill_for_invoice(invoice.id) ->
        {:error, :live_e_way_bill}

      true ->
        with {:ok, cancelled} <-
               invoice |> Ecto.Changeset.change(status: "Cancelled") |> Repo.update() do
          QuantumBilling.Audit.log_event(
            :invoice_cancelled,
            "Invoice",
            cancelled.id,
            Keyword.put(opts, :details, %{
              "reason" => reason,
              "number" => cancelled.invoice_number
            })
          )

          broadcast_change(cancelled, :invoice_changed)
          Webhooks.publish("invoice.cancelled", cancelled.id)
          {:ok, cancelled}
        end
    end
  end

  @doc """
  Moves an invoice to the Bin.

  Nothing is removed: the invoice, its line items, its e-way bills and its
  credit notes all stay in the database, and the invoice simply stops being
  read by anything but the Bin page. `restore_invoice/2` undoes this exactly;
  `purge_invoice/2` is the delete that cannot be undone.

  The number is not returned to the series either way: `invoice_next_number`
  only ever goes forward, so a deleted invoice leaves a gap rather than letting
  the next save reuse a number that has already been out in the world.

  `opts` may carry `:user_id`, recorded against the audit entry.
  """
  def delete_invoice(%Invoice{} = invoice, opts \\ []) do
    invoice
    |> Invoice.bin_changeset()
    |> Repo.update()
    |> announce(:bin_invoice, opts)
  end

  @doc """
  Takes an invoice back out of the Bin.
  """
  def restore_invoice(%Invoice{} = invoice, opts \\ []) do
    invoice
    |> Invoice.restore_changeset()
    |> Repo.update()
    |> announce(:restore_invoice, opts)
  end

  @doc """
  Deletes an invoice for good, along with its line items.

  Its e-way bills and credit notes go with it — the database cascades them —
  which is why this is only offered from the Bin, behind a confirmation, and
  only for an invoice that is already there.
  """
  def purge_invoice(invoice, opts \\ [])

  def purge_invoice(%Invoice{deleted_at: nil}, _opts), do: {:error, :not_in_bin}

  def purge_invoice(%Invoice{} = invoice, opts) do
    invoice
    |> Repo.delete()
    |> announce(:purge_invoice, opts)
  end

  defp announce({:ok, invoice} = result, action, opts) do
    Audit.log_event(action, "Invoice", invoice.id,
      user_id: Keyword.get(opts, :user_id),
      details: %{
        invoice_number: invoice.invoice_number,
        client_name: invoice.client_name,
        # Whole rupees, as older entries in the log hold.
        grand_total: div(invoice.grand_total || 0, 100)
      }
    )

    broadcast_change(invoice, :invoice_changed)
    result
  end

  defp announce({:error, _changeset} = result, _action, _opts), do: result

  # These build the `trusted` half of the changeset: values the application
  # decides, which no params can override.
  defp with_number(trusted, organization) do
    Map.put(trusted, :invoice_number, Settings.next_invoice_number(organization))
  end

  defp with_company_snapshot(trusted, organization) do
    Map.merge(trusted, company_snapshot(organization))
  end

  @doc """
  The issuing company as `organization` describes it now, as trusted invoice
  fields. For the form's live preview, which needs the company's state to split
  the tax; `create_invoice/1` takes its own snapshot under the numbering lock.
  """
  def company_snapshot(%Organization{} = organization) do
    %{
      company_name: organization.company_name,
      company_address: organization.address,
      company_gstin: organization.gstin,
      company_state: organization.state
    }
  end

  defp resolve_template(attrs) do
    case template_id_from(attrs) do
      nil -> Templates.default_template()
      id -> Templates.get_template(id) || Templates.default_template()
    end
  end

  defp with_layout_snapshot(trusted, %{id: id, layout_xml: xml}, _organization) do
    Map.merge(trusted, %{template_id: id, layout_xml: xml})
  end

  # No design exists yet; freeze the default layout so later edits don't change this invoice.
  defp with_layout_snapshot(trusted, nil, _organization) do
    Map.merge(trusted, %{template_id: nil, layout_xml: Catalog.classic() |> Layout.to_xml()})
  end

  # Judged by the stored status, not the params, so a sent document is never re-frozen.
  defp refresh_layout(attrs, %Invoice{status: "Draft"}) do
    with_layout_snapshot(%{}, resolve_template(attrs), Settings.get_organization())
  end

  defp refresh_layout(_attrs, %Invoice{}), do: %{}

  # A sent invoice keeps the design it went out with, so its template cannot be
  # switched from the form either.
  defp drop_layout_unless_draft(attrs, %Invoice{status: "Draft"}), do: attrs

  defp drop_layout_unless_draft(attrs, %Invoice{}),
    do: Map.drop(attrs, ["template_id", :template_id])

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

  @doc """
  Subscribes the caller to invoice changes.
  """
  def subscribe, do: Events.subscribe(Events.invoices_topic())

  @doc """
  Subscribes the caller to one invoice's changes only.

  What an unauthenticated page must use: see `Events.invoice_topic/1`.
  """
  def subscribe(invoice_id), do: Events.subscribe(Events.invoice_topic(invoice_id))

  @doc """
  Announces an invoice change to every listening page.

  On two topics: the list, dashboard and report pages want every change, and
  the public payment page wants exactly one invoice and has no business
  receiving the rest.
  """
  def broadcast_change(invoice, event \\ :invoice_changed) do
    Events.broadcast(Events.invoices_topic(), {event, invoice})

    case invoice do
      %{id: id} when not is_nil(id) ->
        Events.broadcast(Events.invoice_topic(id), {event, invoice})

      _no_id ->
        :ok
    end
  end

  defdelegate invoice_types(), to: Invoice
  defdelegate payment_terms(), to: Invoice
  defdelegate statuses(), to: Invoice
end
