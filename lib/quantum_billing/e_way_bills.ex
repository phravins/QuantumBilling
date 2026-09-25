defmodule QuantumBilling.EWayBills do
  @moduledoc """
  E-way bills: raising them, cancelling them, and updating Part-B.

  ## Where the data lives

  A bill is a row in `e_way_bills` belonging to an invoice. It used to be eight
  columns on the invoice itself, which meant a document could carry exactly one
  bill for ever — so Rule 138(9) cancellation (which spends a number and
  expects a fresh one) and Part-B vehicle updates (which the form prints as a
  table of legs) had nowhere to go.

  ## Status

  `"Active"` and `"Cancelled"` are stored. `"Expired"` is derived from
  `valid_until` by `status/1`, because expiry is a fact about the clock rather
  than about the bill: storing it would need a job to keep it true.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Audit
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.EWayBills.PartBUpdate
  alias QuantumBilling.EWayBillNotifier
  alias QuantumBilling.Events
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  # Sort key to column. An allowlist, so the sort a browser asks for can never
  # reach the query as an arbitrary column name. `value` lives on the invoice,
  # which is why it is tagged with the binding it belongs to.
  @sortable %{
    ewb_no: {:bill, :ewb_number},
    issued_on: {:bill, :ewb_date},
    value: {:invoice, :grand_total}
  }

  @statuses ["Active", "Expired", "Cancelled"]

  # Rule 138(9): a bill may be cancelled within twenty-four hours of generation.
  @cancellation_window_hours 24

  @default_per_page 10
  @max_per_page 200

  @doc """
  Raises an e-way bill against an invoice.

  Returns `{:ok, %EWayBill{}}` with the invoice preloaded, or `{:error, reason}`
  — `:already_issued` when the invoice already has a live bill, `:cancelled`
  when the invoice itself is cancelled, a changeset, or whatever the portal
  said.
  """
  def generate_e_way_bill(%Invoice{} = invoice, params \\ %{}) do
    with :ok <- ensure_issuable(invoice),
         {:ok, attrs} <- NICClient.generate_ewb(invoice, params) do
      attrs = attrs |> Map.put(:invoice_id, invoice.id) |> Map.put(:status, "Active")

      %EWayBill{}
      |> EWayBill.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, bill} ->
          bill = preload_bill(bill)

          Audit.log_event(:generate_e_way_bill, "EWayBill", bill.id,
            details: %{
              ewb_number: bill.ewb_number,
              invoice_id: invoice.id,
              invoice_number: invoice.invoice_number,
              distance_km: bill.distance_km,
              vehicle_number: bill.vehicle_number
            }
          )

          # Gated on `notify_ewb_generated`, and deliberately not matched on:
          # the bill exists at the government's end whatever the mail relay
          # does, so a notice that cannot be queued must not turn a successful
          # generation into an error.
          _ = EWayBillNotifier.notify_generated(bill)

          broadcast_change(bill)
          {:ok, bill}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Cancels a bill under Rule 138(9).

  The rule allows cancellation within twenty-four hours of generation, and
  requires a reason. A bill that is already cancelled, or whose window has
  closed, is refused — on the portal the number would simply stay spent, and
  recording a cancellation here that the portal did not accept would make this
  table disagree with the government's.

  Returns `{:ok, %EWayBill{}}`, or `{:error, :already_cancelled | :window_closed}`
  or a changeset.
  """
  def cancel_e_way_bill(%EWayBill{} = bill, params \\ %{}) do
    with :ok <- ensure_cancellable(bill),
         {:ok, _portal} <- NICClient.cancel_ewb(bill, params) do
      bill
      |> EWayBill.cancel_changeset(params)
      |> Repo.update()
      |> case do
        {:ok, cancelled} ->
          cancelled = preload_bill(cancelled)

          Audit.log_event(:cancel_e_way_bill, "EWayBill", cancelled.id,
            details: %{
              ewb_number: cancelled.ewb_number,
              reason: cancelled.cancellation_reason
            }
          )

          broadcast_change(cancelled)
          {:ok, cancelled}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Records a Part-B update: the consignment has moved to another vehicle.

  Writes a history row and moves the bill's own `vehicle_number` and
  `mode_of_transport` to the new leg, so the document shows both where it is
  now and how it got there. A cancelled or expired bill cannot be updated —
  the portal will not accept Part-B against either.
  """
  def update_part_b(%EWayBill{} = bill, params) do
    with :ok <- ensure_updatable(bill),
         {:ok, _portal} <- NICClient.update_part_b(bill, params) do
      attrs = Map.put(stringify(params), "e_way_bill_id", bill.id)

      Ecto.Multi.new()
      |> Ecto.Multi.run(:first_leg, fn _repo, _changes -> ensure_first_leg(bill) end)
      |> Ecto.Multi.insert(:part_b, PartBUpdate.changeset(%PartBUpdate{}, attrs))
      |> Ecto.Multi.update(:bill, fn %{part_b: part_b} ->
        Ecto.Changeset.change(bill, %{
          vehicle_number: part_b.vehicle_number,
          mode_of_transport: part_b.mode_of_transport
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{bill: updated, part_b: part_b}} ->
          updated = preload_bill(updated, force: true)

          Audit.log_event(:update_e_way_bill_part_b, "EWayBill", updated.id,
            details: %{
              ewb_number: updated.ewb_number,
              vehicle_number: part_b.vehicle_number,
              mode_of_transport: part_b.mode_of_transport,
              place: part_b.place
            }
          )

          broadcast_change(updated)
          {:ok, updated}

        {:error, _step, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  One bill by id, with its invoice and Part-B history, or `nil`.
  """
  def get_e_way_bill(id) do
    EWayBill
    |> Repo.get(id)
    |> preload_bill()
  end

  @doc """
  One bill by id, raising when it does not exist.
  """
  def get_e_way_bill!(id) do
    EWayBill
    |> Repo.get!(id)
    |> preload_bill()
  end

  @doc """
  The live (not cancelled) bill for an invoice, or `nil`.
  """
  def live_bill_for_invoice(invoice_id) do
    EWayBill
    |> where([b], b.invoice_id == ^invoice_id and b.status != "Cancelled")
    |> Repo.one()
    |> preload_bill()
  end

  @doc """
  Every e-way bill, newest first, shaped for the list page.

  Unbounded: for exports and tests. The page itself uses `page/1`.
  """
  def list_e_way_bills do
    base_query()
    |> order_by([bill: b], desc: b.ewb_date, desc: b.id)
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc """
  One page of e-way bills, searched, filtered, sorted and counted by the
  database.

  Returns `%{rows:, total:, page:, per_page:, total_pages:}`, the same shape the
  invoice list uses, so both pages paginate identically.

  ## Options

    * `:search` — matches the EWB number, the document number or the consignee
    * `:status` — `"Active"`, `"Expired"`, `"Cancelled"`, or `"All Status"`
    * `:sort_field` / `:sort_dir` — a key of `sortable_fields/0`, `:asc` or `:desc`
    * `:page` / `:per_page`
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp(1, @max_per_page)

    query =
      base_query()
      |> search_where(Keyword.get(opts, :search))
      |> status_where(Keyword.get(opts, :status))

    total = Repo.aggregate(query, :count, :id)
    total_pages = max(ceil(total / per_page), 1)
    page = opts |> Keyword.get(:page, 1) |> clamp(1, total_pages)

    rows =
      query
      |> order(Keyword.get(opts, :sort_field, :issued_on), Keyword.get(opts, :sort_dir, :desc))
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()
      |> Enum.map(&to_row/1)

    %{rows: rows, total: total, page: page, per_page: per_page, total_pages: total_pages}
  end

  @doc """
  Every bill matching the list page's filters, shaped for a CSV export.

  Takes the same `:search` and `:status` options as `page/1` and deliberately
  ignores `:page` — the file a user downloads should hold everything they are
  looking at, not the ten rows currently on screen. The Export button used to
  point at the reports endpoint with `report_type=E-Way+Bills`, which that
  endpoint does not recognise, so it silently handed back a GST tax summary.
  """
  def export_rows(opts \\ []) do
    base_query()
    |> search_where(Keyword.get(opts, :search))
    |> status_where(Keyword.get(opts, :status))
    |> order(Keyword.get(opts, :sort_field, :issued_on), Keyword.get(opts, :sort_dir, :desc))
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc "The columns the list page may sort on."
  def sortable_fields, do: Map.keys(@sortable)

  @doc "The statuses the list page may filter on, the catch-all first."
  def status_options, do: ["All Status" | @statuses]

  @doc "How long after generation a bill may still be cancelled, in hours."
  def cancellation_window_hours, do: @cancellation_window_hours

  @doc """
  Whether this bill is still inside its Rule 138(9) cancellation window.
  """
  def cancellable?(%EWayBill{} = bill), do: ensure_cancellable(bill) == :ok

  @doc """
  What an e-way bill's status is.

  `"Cancelled"` is stored. `"Expired"` is derived by comparing `valid_until`
  with now, because it is a fact about the clock rather than about the bill.
  """
  def status(%EWayBill{status: "Cancelled"}), do: "Cancelled"
  def status(%EWayBill{valid_until: nil}), do: "Active"

  def status(%EWayBill{valid_until: valid_until}) do
    if NaiveDateTime.compare(valid_until, NaiveDateTime.utc_now()) == :lt,
      do: "Expired",
      else: "Active"
  end

  defp ensure_issuable(%Invoice{status: "Cancelled"}), do: {:error, :cancelled}

  defp ensure_issuable(%Invoice{id: id}) do
    exists =
      EWayBill
      |> where([b], b.invoice_id == ^id and b.status != "Cancelled")
      |> Repo.exists?()

    if exists, do: {:error, :already_issued}, else: :ok
  end

  defp ensure_cancellable(%EWayBill{status: "Cancelled"}), do: {:error, :already_cancelled}

  defp ensure_cancellable(%EWayBill{inserted_at: nil}), do: :ok

  defp ensure_cancellable(%EWayBill{inserted_at: generated_at}) do
    hours = DateTime.diff(DateTime.utc_now(), generated_at, :second) / 3600

    if hours <= @cancellation_window_hours, do: :ok, else: {:error, :window_closed}
  end

  defp ensure_updatable(%EWayBill{} = bill) do
    case status(bill) do
      "Active" -> :ok
      "Cancelled" -> {:error, :already_cancelled}
      "Expired" -> {:error, :expired}
    end
  end

  defp preload_bill(bill, opts \\ [])

  defp preload_bill(nil, _opts), do: nil

  # The items come too: the goods table is the part of Form GST EWB-01 an
  # officer actually reads, and without them it prints empty.
  defp preload_bill(%EWayBill{} = bill, opts) do
    Repo.preload(
      bill,
      [
        invoice: :items,
        part_b_updates: from(p in PartBUpdate, order_by: [asc: p.updated_on, asc: p.id])
      ],
      opts
    )
  end

  # Part-B is a table of legs, and the first leg is the vehicle the bill was
  # raised with. Nothing records it while it is still the only one — the bill's
  # own `vehicle_number` says it — so the first update writes it down before
  # overwriting it, or the journey would begin at its second vehicle.
  defp ensure_first_leg(%EWayBill{} = bill) do
    recorded? = Repo.exists?(from p in PartBUpdate, where: p.e_way_bill_id == ^bill.id)

    if recorded? do
      {:ok, :already_recorded}
    else
      Repo.insert(
        PartBUpdate.changeset(%PartBUpdate{}, %{
          "e_way_bill_id" => bill.id,
          "vehicle_number" => bill.vehicle_number,
          "mode_of_transport" => bill.mode_of_transport,
          "updated_on" => bill.inserted_at
        })
      )
    end
  end

  # Named bindings, because the row the list page renders is half bill and half
  # invoice — the number and the vehicle come from one, the consignee and the
  # value from the other.
  defp base_query do
    from b in EWayBill,
      as: :bill,
      join: i in assoc(b, :invoice),
      as: :invoice,
      preload: [invoice: i]
  end

  defp search_where(query, blank) when blank in [nil, ""], do: query

  defp search_where(query, search) do
    pattern = "%" <> String.trim(search) <> "%"

    where(
      query,
      [bill: b, invoice: i],
      ilike(b.ewb_number, ^pattern) or ilike(i.invoice_number, ^pattern) or
        ilike(i.client_name, ^pattern)
    )
  end

  defp status_where(query, status) when status in [nil, "", "All Status"], do: query

  defp status_where(query, "Cancelled"), do: where(query, [bill: b], b.status == "Cancelled")

  defp status_where(query, "Expired") do
    now = NaiveDateTime.utc_now()

    where(query, [bill: b], b.status != "Cancelled" and b.valid_until < ^now)
  end

  defp status_where(query, "Active") do
    now = NaiveDateTime.utc_now()

    where(query, [bill: b], b.status != "Cancelled" and b.valid_until >= ^now)
  end

  defp status_where(query, _unknown), do: query

  defp order(query, field, direction) do
    {binding, column} = Map.get(@sortable, field, {:bill, :ewb_date})
    direction = if direction == :asc, do: :asc, else: :desc

    # The id breaks ties, so two bills issued on the same day cannot swap
    # places between one page and the next.
    case binding do
      :bill ->
        order_by(query, [bill: b], [{^direction, field(b, ^column)}, {^direction, b.id}])

      :invoice ->
        order_by(query, [bill: b, invoice: i], [
          {^direction, field(i, ^column)},
          {^direction, b.id}
        ])
    end
  end

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  defp stringify(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  # The list page's own vocabulary. It was written against a shape no schema
  # ever had — `ewb_no`, `to_party`, `value` — so every row raised a KeyError
  # as soon as one real bill existed. The keys are unchanged now the bill has
  # a table of its own; only where they are read from moved.
  defp to_row(%EWayBill{invoice: %Invoice{} = invoice} = bill) do
    %{
      id: bill.id,
      invoice_id: invoice.id,
      ewb_no: bill.ewb_number,
      document_no: invoice.invoice_number,
      issued_on: bill.ewb_date,
      valid_until: bill.valid_until,
      to_party: invoice.client_name,
      from_place: invoice.company_state || "—",
      to_place: invoice.client_state || invoice.place_of_supply || "—",
      value: invoice.grand_total,
      distance_km: bill.distance_km,
      vehicle_number: bill.vehicle_number,
      transporter_name: bill.transporter_name,
      mode_of_transport: bill.mode_of_transport,
      status: status(bill),
      # Computed here rather than in the template, because the Rule 138(9)
      # window is measured from `inserted_at`, which the row does not carry and
      # the list page has no business knowing about.
      cancellable: cancellable?(bill)
    }
  end

  @doc """
  Subscribes the caller to e-way bill changes.
  """
  def subscribe, do: Events.subscribe(Events.e_way_bills_topic())

  @doc """
  Announces an e-way bill change to every listening page.
  """
  def broadcast_change(e_way_bill, event \\ :e_way_bill_changed) do
    Events.broadcast(Events.e_way_bills_topic(), {event, e_way_bill})
  end
end
