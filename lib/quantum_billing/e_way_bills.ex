defmodule QuantumBilling.EWayBills do
  @moduledoc """
  Context for managing E-Way Bills and communicating with Govt NIC API.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Events
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.Audit
  alias QuantumBilling.Repo

  # Sort key to column. An allowlist, so the sort a browser asks for can never
  # reach the query as an arbitrary column name.
  @sortable %{
    ewb_no: :ewb_number,
    issued_on: :ewb_date,
    value: :grand_total
  }

  @statuses ["Active", "Expired", "Cancelled"]

  @default_per_page 10
  @max_per_page 200

  @doc """
  Generates an E-Way Bill for an invoice and stores the details on the invoice.
  """
  def generate_e_way_bill(%Invoice{} = invoice, params \\ %{}) do
    case NICClient.generate_ewb(invoice, params) do
      {:ok, ewb_attrs} ->
        changeset = Ecto.Changeset.change(invoice, ewb_attrs)

        case Repo.update(changeset) do
          {:ok, updated_invoice} ->
            Audit.log_event(
              :generate_e_way_bill,
              "Invoice",
              updated_invoice.id,
              details: %{
                ewb_number: updated_invoice.ewb_number,
                distance_km: updated_invoice.distance_km,
                vehicle_number: updated_invoice.vehicle_number
              }
            )

            broadcast_change(updated_invoice)
            {:ok, updated_invoice}

          {:error, cs} ->
            {:error, cs}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Every e-way bill, newest first, shaped for the list page.

  Unbounded: for exports and tests. The page itself uses `page/1`.
  """
  def list_e_way_bills do
    base_query()
    |> order_by([i], desc: i.ewb_date, desc: i.id)
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

  @doc "The columns the list page may sort on."
  def sortable_fields, do: Map.keys(@sortable)

  @doc "The statuses the list page may filter on, the catch-all first."
  def status_options, do: ["All Status" | @statuses]

  @doc """
  What an e-way bill's status is, derived rather than stored.

  There is no status column: a bill is cancelled when its invoice is, expired
  once it is past the validity the portal returned, and active until then.
  """
  def status(%Invoice{status: "Cancelled"}), do: "Cancelled"
  def status(%Invoice{ewb_valid_until: nil}), do: "Active"

  def status(%Invoice{ewb_valid_until: valid_until}) do
    if NaiveDateTime.compare(valid_until, NaiveDateTime.utc_now()) == :lt,
      do: "Expired",
      else: "Active"
  end

  defp base_query, do: from(i in Invoice, where: not is_nil(i.ewb_number))

  defp search_where(query, blank) when blank in [nil, ""], do: query

  defp search_where(query, search) do
    pattern = "%" <> String.trim(search) <> "%"

    where(
      query,
      [i],
      ilike(i.ewb_number, ^pattern) or ilike(i.invoice_number, ^pattern) or
        ilike(i.client_name, ^pattern)
    )
  end

  defp status_where(query, status) when status in [nil, "", "All Status"], do: query

  defp status_where(query, "Cancelled"), do: where(query, [i], i.status == "Cancelled")

  defp status_where(query, "Expired") do
    now = NaiveDateTime.utc_now()

    where(
      query,
      [i],
      i.status != "Cancelled" and not is_nil(i.ewb_valid_until) and i.ewb_valid_until < ^now
    )
  end

  defp status_where(query, "Active") do
    now = NaiveDateTime.utc_now()

    where(
      query,
      [i],
      i.status != "Cancelled" and (is_nil(i.ewb_valid_until) or i.ewb_valid_until >= ^now)
    )
  end

  defp status_where(query, _unknown), do: query

  defp order(query, field, direction) do
    column = Map.get(@sortable, field, :ewb_date)
    direction = if direction == :asc, do: :asc, else: :desc

    # The id breaks ties, so two bills issued on the same day cannot swap
    # places between one page and the next.
    order_by(query, [i], [{^direction, field(i, ^column)}, {^direction, i.id}])
  end

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  # The list page's own vocabulary. It was written against a shape no schema
  # ever had — `ewb_no`, `to_party`, `value` — so every row raised a KeyError
  # as soon as one real bill existed.
  defp to_row(%Invoice{} = invoice) do
    %{
      id: invoice.id,
      ewb_no: invoice.ewb_number,
      document_no: invoice.invoice_number,
      issued_on: invoice.ewb_date,
      valid_until: invoice.ewb_valid_until,
      to_party: invoice.client_name,
      from_place: invoice.company_state || "—",
      to_place: invoice.client_state || invoice.place_of_supply || "—",
      value: invoice.grand_total,
      distance_km: invoice.distance_km,
      vehicle_number: invoice.vehicle_number,
      transporter_name: invoice.transporter_name,
      mode_of_transport: invoice.mode_of_transport,
      status: status(invoice)
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
