defmodule QuantumBilling.Reports do
  @moduledoc """
  Aggregations behind the Reports page.

  Every panel on that page — the metric cards, both charts, the tax summary and
  the top-clients list — is a different view of one set of invoices, and the
  filters have to move all of them together. So this module works from
  **row-level** invoices and derives each panel from them, rather than holding
  per-panel display values.

  `invoices/0` is a placeholder pending the multi-tenant Ecto schema. Every
  function below it already takes a list and handles the empty case, so when the
  schema lands only `invoices/0` changes.

  A row is `%{date, client, gstin, status, tax_type, taxable_value, cgst, sgst,
  igst, cess}`, with money as whole rupees (integers) throughout — matching
  `QuantumBilling.EWayBills.EWayBillForm`, so `QuantumBillingWeb.Format.rupees/2`
  can render it. `tax_type` is `"CGST + SGST"`, `"IGST"` or `"CESS"` and must
  agree with which tax columns are non-zero.
  """

  @report_types [
    "All Reports",
    "Sales Register",
    "Tax Liability",
    "ITC Summary"
  ]

  @statuses ["E-Invoice Generated", "Pending E-Invoice", "E-Invoice Failed", "Cancelled"]

  @date_ranges ["This Month", "Last Month", "This Quarter", "This Year", "All Time"]

  import Ecto.Query, warn: false

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  @doc """
  Every invoice available to report on.

  Reads all invoices from the database, newest first, and transforms them into
  report rows.
  """
  def invoices do
    Repo.all(from i in Invoice, order_by: [desc: i.invoice_date, desc: i.id])
    |> Enum.map(&to_row/1)
  end

  @doc """
  Converts an `Invoice` struct or map into a report row.
  """
  def to_row(%Invoice{} = invoice) do
    tax_type =
      cond do
        (invoice.cgst_amount || 0) > 0 or (invoice.sgst_amount || 0) > 0 ->
          "CGST + SGST"

        (invoice.igst_amount || 0) > 0 ->
          "IGST"

        (invoice.cess_amount || 0) > 0 ->
          "CESS"

        Invoice.intra_state?(invoice) ->
          "CGST + SGST"

        true ->
          "IGST"
      end

    %{
      id: invoice.id,
      number: invoice.invoice_number,
      date: invoice.invoice_date,
      client: invoice.client_name || "Unknown Client",
      gstin: invoice.client_gstin || "",
      status: invoice.status,
      tax_type: tax_type,
      taxable_value: invoice.taxable_value || 0,
      cgst: invoice.cgst_amount || 0,
      sgst: invoice.sgst_amount || 0,
      igst: invoice.igst_amount || 0,
      cess: invoice.cess_amount || 0
    }
  end

  def to_row(row) when is_map(row), do: row

  @doc """
  Narrows `invoices` by the active filters.

  Unset filters, and the "All …" sentinel options, match everything. GSTIN is a
  case-insensitive substring match so a partial code still narrows.
  """
  def filter(invoices, filters) do
    {from, to} = range_bounds(filters[:date_range])

    invoices
    |> Enum.filter(&within?(&1.date, from, to))
    |> Enum.filter(&matches?(&1.status, filters[:status], "All Status"))
    |> Enum.filter(&matches?(&1.client, filters[:client], "All Clients"))
    |> Enum.filter(&matches_report_type?(&1, filters[:report_type]))
    |> Enum.filter(&matches_gstin?(&1, filters[:gstin]))
  end

  defp within?(_date, nil, nil), do: true

  defp within?(date, from, to),
    do: Date.compare(date, from) != :lt and Date.compare(date, to) != :gt

  defp matches?(_value, nil, _all), do: true
  defp matches?(_value, all, all), do: true
  defp matches?(value, filter, _all), do: value == filter

  # "Sales Register" is every invoice; the other report types narrow to the
  # rows that report actually concerns.
  defp matches_report_type?(_row, nil), do: true
  defp matches_report_type?(_row, "All Reports"), do: true
  defp matches_report_type?(_row, "Sales Register"), do: true
  defp matches_report_type?(row, "Tax Liability"), do: row.status == "E-Invoice Generated"
  defp matches_report_type?(row, "ITC Summary"), do: row.cess == 0
  defp matches_report_type?(_row, _other), do: true

  defp matches_gstin?(_row, nil), do: true
  defp matches_gstin?(_row, ""), do: true

  defp matches_gstin?(row, gstin) do
    String.contains?(String.upcase(row.gstin), String.upcase(String.trim(gstin)))
  end

  @doc """
  Totals for the four metric cards, with a month-over-month delta for each.

  The delta compares the latest month present in `invoices` against the month
  before it, which is what the cards' "from last month" caption claims.
  """
  def summary(invoices) do
    taxable = sum_by(invoices, & &1.taxable_value)
    tax = sum_by(invoices, &row_tax/1)

    %{
      count: length(invoices),
      taxable_value: taxable,
      tax_amount: tax,
      invoice_value: taxable + tax,
      count_delta: delta(invoices, fn rows -> length(rows) end),
      taxable_delta: delta(invoices, &sum_by(&1, fn r -> r.taxable_value end)),
      tax_delta: delta(invoices, &sum_by(&1, fn r -> row_tax(r) end)),
      invoice_delta: delta(invoices, &sum_by(&1, fn r -> r.taxable_value + row_tax(r) end))
    }
  end

  defp row_tax(row), do: row.cgst + row.sgst + row.igst + row.cess

  defp sum_by(rows, fun), do: Enum.reduce(rows, 0, fn row, acc -> acc + fun.(row) end)

  # Percentage change between the last two months represented in the set.
  # Returns nil when there is nothing to compare against, so the caller can omit
  # the caption rather than print a meaningless 0%.
  defp delta([], _measure), do: nil

  defp delta(invoices, measure) do
    months = invoices |> Enum.map(&month_key/1) |> Enum.uniq() |> Enum.sort()

    case Enum.take(months, -2) do
      [previous, current] ->
        prev_value = invoices |> Enum.filter(&(month_key(&1) == previous)) |> measure.()
        curr_value = invoices |> Enum.filter(&(month_key(&1) == current)) |> measure.()

        if prev_value == 0, do: nil, else: (curr_value - prev_value) / prev_value * 100

      _fewer_than_two_months ->
        nil
    end
  end

  defp month_key(row), do: {row.date.year, row.date.month}

  @doc """
  Monthly invoice value for the trend chart, oldest month first, as
  `[%{label, value}]` with `label` like `"Jan"`.
  """
  def monthly_trend(invoices) do
    invoices
    |> Enum.group_by(&month_key/1)
    |> Enum.sort_by(fn {key, _rows} -> key end)
    |> Enum.map(fn {{year, month}, rows} ->
      %{
        label: Calendar.strftime(Date.new!(year, month, 1), "%b"),
        value: sum_by(rows, &(&1.taxable_value + row_tax(&1)))
      }
    end)
  end

  @doc """
  Invoice counts per status for the donut, in a fixed order so the ring's
  colours stay stable as the data changes. Statuses with no rows are dropped.
  """
  def status_breakdown(invoices) do
    counts = Enum.frequencies_by(invoices, & &1.status)

    [
      %{label: "E-Invoice Generated", value: counts["E-Invoice Generated"] || 0, tone: :strong},
      %{label: "Pending", value: counts["Pending E-Invoice"] || 0, tone: :medium},
      %{label: "Failed", value: counts["E-Invoice Failed"] || 0, tone: :soft},
      %{label: "Cancelled", value: counts["Cancelled"] || 0, tone: :faint}
    ]
    |> Enum.reject(&(&1.value == 0))
  end

  @doc """
  One row per tax type plus a totals row, shaped for the tax summary table.

  `nil` in a column means "not applicable to this tax type" and renders as a
  dash — CGST/SGST never apply to an inter-state supply, and vice versa.
  """
  def tax_summary(invoices) do
    groups = Enum.group_by(invoices, & &1.tax_type)

    rows =
      [
        tax_row(groups["CGST + SGST"], "CGST + SGST", :intra),
        tax_row(groups["IGST"], "IGST", :inter),
        tax_row(groups["CESS"], "CESS", :cess)
      ]
      |> Enum.reject(&is_nil/1)

    rows ++ [totals_row(rows)]
  end

  defp tax_row(nil, _label, _kind), do: nil
  defp tax_row([], _label, _kind), do: nil

  defp tax_row(rows, label, kind) do
    cgst = sum_by(rows, & &1.cgst)
    sgst = sum_by(rows, & &1.sgst)
    igst = sum_by(rows, & &1.igst)
    cess = sum_by(rows, & &1.cess)

    %{
      label: label,
      taxable_value: sum_by(rows, & &1.taxable_value),
      cgst: if(kind == :intra, do: cgst),
      sgst: if(kind == :intra, do: sgst),
      igst: if(kind == :inter, do: igst),
      total_tax: cgst + sgst + igst + cess,
      total?: false
    }
  end

  defp totals_row(rows) do
    %{
      label: "Total",
      taxable_value: sum_by(rows, & &1.taxable_value),
      cgst: sum_present(rows, & &1.cgst),
      sgst: sum_present(rows, & &1.sgst),
      igst: sum_present(rows, & &1.igst),
      total_tax: sum_by(rows, & &1.total_tax),
      total?: true
    }
  end

  # Totals only cover the columns that actually applied to some row, so an
  # all-inter-state period shows a dash under CGST rather than a misleading 0.
  defp sum_present(rows, fun) do
    case Enum.filter(rows, &(fun.(&1) != nil)) do
      [] -> nil
      present -> sum_by(present, fun)
    end
  end

  @doc """
  The five clients with the highest total invoice value, descending.
  """
  def top_clients(invoices, limit \\ 5) do
    invoices
    |> Enum.group_by(& &1.client)
    |> Enum.map(fn {client, rows} ->
      %{client: client, value: sum_by(rows, &(&1.taxable_value + row_tax(&1)))}
    end)
    |> Enum.sort_by(& &1.value, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Resolves a named range to `{from, to}` dates, or `{nil, nil}` for "All Time".

  Relative to today. Pass `today` explicitly to make a test deterministic rather
  than dependent on when it runs.
  """
  def range_bounds(range, today \\ nil)

  def range_bounds(nil, today), do: range_bounds("This Year", today)
  def range_bounds("All Time", _today), do: {nil, nil}

  def range_bounds("This Month", today) do
    today = today || Date.utc_today()
    {Date.beginning_of_month(today), Date.end_of_month(today)}
  end

  def range_bounds("Last Month", today) do
    previous = (today || Date.utc_today()) |> Date.beginning_of_month() |> Date.add(-1)
    {Date.beginning_of_month(previous), Date.end_of_month(previous)}
  end

  def range_bounds("This Quarter", today) do
    today = today || Date.utc_today()
    from = Date.new!(today.year, div(today.month - 1, 3) * 3 + 1, 1)
    {from, from |> Date.add(62) |> Date.end_of_month()}
  end

  def range_bounds("This Year", today) do
    today = today || Date.utc_today()
    {Date.new!(today.year, 1, 1), Date.new!(today.year, 12, 31)}
  end

  def range_bounds(_unknown, today), do: range_bounds("This Year", today)

  @doc """
  Human label for a range, e.g. `"01 May 2024 - 31 May 2024"`.
  """
  def range_label(range, today \\ nil) do
    case range_bounds(range, today) do
      {nil, nil} ->
        "All time"

      {from, to} ->
        QuantumBillingWeb.Format.format_date(from) <>
          " - " <> QuantumBillingWeb.Format.format_date(to)
    end
  end

  @doc "The filter state a freshly loaded page starts from."
  def default_filters do
    %{
      date_range: "This Year",
      report_type: "All Reports",
      client: "All Clients",
      status: "All Status",
      gstin: ""
    }
  end

  def report_types, do: @report_types
  def statuses, do: ["All Status" | @statuses]
  def date_ranges, do: @date_ranges

  @doc """
  Names for the client filter.

  Returns "All Clients" followed by distinct client names from registered clients
  and issued invoices, sorted alphabetically.
  """
  def client_names do
    names =
      (Repo.all(from c in Client, select: c.name, where: not is_nil(c.name)) ++
         Repo.all(from i in Invoice, select: i.client_name, where: not is_nil(i.client_name)))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort()

    ["All Clients" | names]
  end
end
