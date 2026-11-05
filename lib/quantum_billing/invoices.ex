defmodule QuantumBilling.Invoices do
  @moduledoc """
  GST invoices.

  Numbers are taken from `invoice_next_number` in the same transaction as the
  insert, so the series has no duplicates. Deleting moves an invoice to the
  Bin; every read goes through `Invoice.kept/1`, so binned invoices are hidden.
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

  @doc "Every invoice, newest first. Unbounded; use `page/1` for screens."
  def list_invoices do
    Repo.all(from i in Invoice.kept(), order_by: [desc: i.invoice_date, desc: i.id])
    |> Enum.map(&to_row/1)
  end

  @doc """
  One page of invoices, filtered and sorted in the database.

  Options: `:search`, `:status`, `:client`, `:sort_field`, `:sort_dir`,
  `:page`, `:per_page`, `:count`, and `:keyset`/`:before_id` for keyset paging.
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

  # `records: true` returns the invoices themselves (used by the API).
  defp shape(result, true), do: result
  defp shape(result, _rows), do: %{result | rows: Enum.map(result.rows, &to_row/1)}

  @doc "The most recently issued invoices, as list rows."
  def recent_invoices(limit \\ 5) do
    Invoice.kept()
    |> order_by([i], desc: i.invoice_date, desc: i.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc """
  Invoices that can still get an e-way bill, newest first.

  Excludes cancelled invoices and those with a live bill. A cancelled bill
  does not exclude its invoice (Rule 138(9)).
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

  @doc "Invoices over the e-way bill threshold that have no live bill."
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
  Counts and totals across every invoice: `%{count:, revenue:, tax:, outstanding:, paid_count:}`.

  `outstanding` is net of credit and debit notes.
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

  Pass `client_ids` to limit the query to those clients.
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

  @doc "Totals for the invoices dated within `month`."
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
  Tax charged per month for the last `count` months, oldest first.

  Months without invoices are included as zeros.
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

  # Matched on client_id, or by name for invoices without one.
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

  @doc "Fetches a non-binned invoice with its items. Raises if missing."
  def get_invoice!(id) do
    Invoice.kept()
    |> Repo.get!(id)
    |> with_items()
  end

  @doc "Fetches an invoice by number. `include_binned: true` also finds binned ones."
  def get_invoice_by_number(invoice_number, opts \\ []) when is_binary(invoice_number) do
    query = if Keyword.get(opts, :include_binned, false), do: Invoice, else: Invoice.kept()

    query
    |> Repo.get_by(invoice_number: invoice_number)
    |> with_items()
  end

  @doc "Fetches a non-binned invoice by its public token."
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
  The client details an invoice records, copied from the client.

  A snapshot, so the invoice keeps saying what it said when issued. Shared by
  the form and the API, so neither takes client details from the request.
  """
  def client_snapshot(%QuantumBilling.Clients.Client{} = client) do
    %{
      "client_id" => client.id,
      "client_name" => client.name,
      "client_gstin" => client.gstin,
      # Every GSTIN contains the PAN.
      "client_pan" => present(client.pan) || QuantumBilling.GST.pan_from_gstin(client.gstin),
      "client_email" => client.email,
      "client_state" => client.billing_state,
      "client_billing_address" => billing_address(client),
      # Stored separately too: the e-invoice export needs them.
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

  @doc "Creates an invoice with the next number in the series."
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
      # Without a settings row every invoice would get number 1.
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

  The number and company block never change. The layout snapshot is refreshed
  only while the invoice is a draft.
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
  Queues IRP registration for an invoice.

  Returns `{:ok, :queued}`, `{:ok, :already_registered}` or `{:error, reason}`.
  The status becomes "Pending E-Invoice" until the job finishes.
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
  Registers an invoice with the IRP and stores the IRN, ack details and QR.

  Called by `EInvoiceWorker`. The invoice is validated against the e-invoice
  schema first.
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

  # Status is not a form field, so it is set directly.
  defp mark_einvoice_failed(invoice) do
    with {:ok, failed} <- Repo.update(Ecto.Changeset.change(invoice, status: "E-Invoice Failed")) do
      broadcast_change(failed, :invoice_changed)
      Webhooks.publish("invoice.e_invoice_failed", failed.id)
    end
  end

  @doc """
  Cancels an invoice. It keeps its number and leaves GSTR-1.

  Refused with `:already_cancelled`, `:paid` (needs a credit note),
  `:irn_registered` or `:live_e_way_bill`. `opts` carries audit fields.
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
  Moves an invoice to the Bin. Nothing is removed and the number is not reused.

  `opts` may carry `:user_id` for the audit entry.
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

  @doc "Deletes a binned invoice for good. Its e-way bills and credit notes cascade."
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

  # Trusted fields: decided by the application, never by params.
  defp with_number(trusted, organization) do
    Map.put(trusted, :invoice_number, Settings.next_invoice_number(organization))
  end

  defp with_company_snapshot(trusted, organization) do
    Map.merge(trusted, company_snapshot(organization))
  end

  @doc "The issuing company as trusted invoice fields, for the form's live preview."
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

  # No design exists yet; freeze the default layout.
  defp with_layout_snapshot(trusted, nil, _organization) do
    Map.merge(trusted, %{template_id: nil, layout_xml: Catalog.classic() |> Layout.to_xml()})
  end

  # Judged by the stored status, so a sent invoice is never re-frozen.
  defp refresh_layout(attrs, %Invoice{status: "Draft"}) do
    with_layout_snapshot(%{}, resolve_template(attrs), Settings.get_organization())
  end

  defp refresh_layout(_attrs, %Invoice{}), do: %{}

  # A sent invoice keeps its design.
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

  @doc "Subscribes the caller to one invoice's changes (for public pages)."
  def subscribe(invoice_id), do: Events.subscribe(Events.invoice_topic(invoice_id))

  @doc "Broadcasts an invoice change to the list topic and the invoice's own topic."
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
