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
  Every invoice available to report on, newest first, as report rows.

  Unfiltered and unbounded, so it is only for a caller that genuinely wants the
  lot — a test, or a console. The page uses `aggregate/1`, which never loads a
  row into memory at all, and the CSV export uses `stream_rows/2`, which reads
  in chunks.
  """
  def invoices do
    Repo.all(from i in Invoice, order_by: [desc: i.invoice_date, desc: i.id])
    |> Enum.map(&to_row/1)
  end

  @doc """
  The invoices matching `filters`, newest first, as report rows.

  The filtering happens in the database. It used to happen in Elixir over every
  invoice ever issued: a report on one month still read the whole table, and
  the cost of opening the Reports page grew with the age of the business.
  """
  def invoices(filters) when is_map(filters) do
    filters
    |> query()
    |> order_by([i], desc: i.invoice_date, desc: i.id)
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc """
  Runs `fun` over the filtered invoices as a stream of report rows.

  For exports. `Repo.stream/1` holds a database cursor and hands over rows in
  chunks, so a sales register covering a year is written out in constant memory
  rather than materialising every row first. It has to run inside a
  transaction, which is what this wraps.
  """
  def stream_rows(filters, fun) when is_map(filters) and is_function(fun, 1) do
    Repo.transaction(
      fn ->
        filters
        |> query()
        |> order_by([i], asc: i.invoice_date, asc: i.id)
        |> Repo.stream(max_rows: 500)
        |> Stream.map(&to_row/1)
        |> fun.()
      end,
      timeout: :timer.minutes(5)
    )
  end

  @doc """
  The query behind every report, with `filters` applied.

  One place, so the page, the export and any future report cannot disagree
  about what "This Quarter, Tax Liability, client X" means.
  """
  def query(filters) when is_map(filters) do
    Invoice
    |> filter_dates(range_bounds(filters[:date_range]))
    |> filter_equal(:status, filters[:status], "All Status")
    |> filter_equal(:client_name, filters[:client], "All Clients")
    |> filter_gstin(filters[:gstin])
    |> filter_report_type(filters[:report_type])
  end

  defp filter_dates(query, {nil, nil}), do: query

  defp filter_dates(query, {from, to}) do
    where(query, [i], i.invoice_date >= ^from and i.invoice_date <= ^to)
  end

  defp filter_equal(query, _field, nil, _all), do: query
  defp filter_equal(query, _field, all, all), do: query
  defp filter_equal(query, _field, "", _all), do: query

  defp filter_equal(query, field, value, _all) do
    where(query, [i], field(i, ^field) == ^value)
  end

  defp filter_gstin(query, blank) when blank in [nil, ""], do: query

  defp filter_gstin(query, gstin) do
    pattern = "%" <> String.trim(gstin) <> "%"
    where(query, [i], ilike(i.client_gstin, ^pattern))
  end

  defp filter_report_type(query, "Tax Liability"),
    do: where(query, [i], i.status == "E-Invoice Generated")

  defp filter_report_type(query, "ITC Summary"),
    do: where(query, [i], coalesce(i.cess_amount, 0) == 0)

  defp filter_report_type(query, _all_or_sales_register), do: query

  @doc """
  Every panel on the Reports page, computed by the database.

  Five aggregate queries rather than one full table scan followed by five
  passes in Elixir. What comes back is the same shape the pure list functions
  below produce, so the page renders identically — it simply stops caring how
  many invoices exist.
  """
  def aggregate(filters) when is_map(filters) do
    months = monthly_breakdown(filters)
    totals = totals(filters)

    %{
      summary: %{
        count: totals.count,
        taxable_value: totals.taxable_value,
        tax_amount: totals.tax_amount,
        invoice_value: totals.taxable_value + totals.tax_amount,
        count_delta: month_delta(months, & &1.count),
        taxable_delta: month_delta(months, & &1.taxable_value),
        tax_delta: month_delta(months, & &1.tax_amount),
        invoice_delta: month_delta(months, &(&1.taxable_value + &1.tax_amount))
      },
      trend: Enum.map(months, &%{label: &1.label, value: &1.taxable_value + &1.tax_amount}),
      breakdown: breakdown_rows(status_counts(filters)),
      tax_rows: tax_rows_from(tax_type_totals(filters)),
      top_clients: top_client_rows(filters),
      total_count: totals.count
    }
  end

  @doc "Row count and money totals for the filtered set."
  def totals(filters) when is_map(filters) do
    filters
    |> query()
    |> select([i], %{
      count: count(i.id),
      taxable_value: coalesce(sum(i.taxable_value), 0),
      tax_amount:
        coalesce(
          sum(
            coalesce(i.cgst_amount, 0) + coalesce(i.sgst_amount, 0) +
              coalesce(i.igst_amount, 0) + coalesce(i.cess_amount, 0)
          ),
          0
        )
    })
    |> Repo.one()
    |> case do
      nil -> %{count: 0, taxable_value: 0, tax_amount: 0}
      totals -> totals
    end
  end

  @doc """
  Per-month totals for the filtered set, oldest first.

  Feeds both the trend chart and the month-over-month deltas on the cards, so
  the two cannot tell different stories about the same month.
  """
  def monthly_breakdown(filters) when is_map(filters) do
    filters
    |> query()
    |> group_by([i], fragment("date_trunc('month', ?)", i.invoice_date))
    |> order_by([i], asc: fragment("date_trunc('month', ?)", i.invoice_date))
    |> select([i], %{
      month: fragment("date_trunc('month', ?)", i.invoice_date),
      count: count(i.id),
      taxable_value: coalesce(sum(i.taxable_value), 0),
      tax_amount:
        coalesce(
          sum(
            coalesce(i.cgst_amount, 0) + coalesce(i.sgst_amount, 0) +
              coalesce(i.igst_amount, 0) + coalesce(i.cess_amount, 0)
          ),
          0
        )
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      Map.put(row, :label, Calendar.strftime(to_date(row.month), "%b"))
    end)
  end

  defp to_date(%Date{} = date), do: date
  defp to_date(%NaiveDateTime{} = naive), do: NaiveDateTime.to_date(naive)
  defp to_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)

  defp month_delta(months, measure) do
    case Enum.take(months, -2) do
      [previous, current] ->
        previous_value = measure.(previous)

        if previous_value == 0 do
          nil
        else
          (measure.(current) - previous_value) / previous_value * 100
        end

      _fewer_than_two_months ->
        nil
    end
  end

  defp status_counts(filters) do
    filters
    |> query()
    |> group_by([i], i.status)
    |> select([i], {i.status, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp breakdown_rows(counts) do
    [
      %{label: "E-Invoice Generated", value: counts["E-Invoice Generated"] || 0, tone: :strong},
      %{label: "Pending", value: counts["Pending E-Invoice"] || 0, tone: :medium},
      %{label: "Failed", value: counts["E-Invoice Failed"] || 0, tone: :soft},
      %{label: "Cancelled", value: counts["Cancelled"] || 0, tone: :faint}
    ]
    |> Enum.reject(&(&1.value == 0))
  end

  # The same rule `to_row/1` applies in Elixir, expressed in SQL so the
  # grouping can happen in the database: which taxes were actually charged,
  # falling back to where the supply went when an invoice carries no tax at all.
  @tax_type_sql """
  CASE
    WHEN COALESCE(cgst_amount, 0) > 0 OR COALESCE(sgst_amount, 0) > 0 THEN 'CGST + SGST'
    WHEN COALESCE(igst_amount, 0) > 0 THEN 'IGST'
    WHEN COALESCE(cess_amount, 0) > 0 THEN 'CESS'
    WHEN company_state IS NULL OR company_state = '' OR place_of_supply = company_state
      THEN 'CGST + SGST'
    ELSE 'IGST'
  END
  """

  defp tax_type_totals(filters) do
    filters
    |> query()
    |> group_by([i], fragment(@tax_type_sql))
    |> select([i], %{
      tax_type: fragment(@tax_type_sql),
      taxable_value: coalesce(sum(i.taxable_value), 0),
      cgst: coalesce(sum(i.cgst_amount), 0),
      sgst: coalesce(sum(i.sgst_amount), 0),
      igst: coalesce(sum(i.igst_amount), 0),
      cess: coalesce(sum(i.cess_amount), 0)
    })
    |> Repo.all()
    |> Map.new(&{&1.tax_type, &1})
  end

  defp tax_rows_from(totals_by_type) do
    rows =
      [
        aggregated_tax_row(totals_by_type["CGST + SGST"], "CGST + SGST", :intra),
        aggregated_tax_row(totals_by_type["IGST"], "IGST", :inter),
        aggregated_tax_row(totals_by_type["CESS"], "CESS", :cess)
      ]
      |> Enum.reject(&is_nil/1)

    # The totals row is present even with nothing to total, matching
    # `tax_summary/1`: the table always shows its bottom line, reading zero.
    rows ++ [totals_row(rows)]
  end

  defp aggregated_tax_row(nil, _label, _kind), do: nil

  defp aggregated_tax_row(totals, label, kind) do
    %{
      label: label,
      taxable_value: totals.taxable_value,
      cgst: if(kind == :intra, do: totals.cgst),
      sgst: if(kind == :intra, do: totals.sgst),
      igst: if(kind == :inter, do: totals.igst),
      total_tax: totals.cgst + totals.sgst + totals.igst + totals.cess,
      total?: false
    }
  end

  defp top_client_rows(filters, limit \\ 5) do
    filters
    |> query()
    |> group_by([i], i.client_name)
    |> select([i], %{
      client: i.client_name,
      value:
        selected_as(
          coalesce(
            sum(
              coalesce(i.taxable_value, 0) + coalesce(i.cgst_amount, 0) +
                coalesce(i.sgst_amount, 0) + coalesce(i.igst_amount, 0) +
                coalesce(i.cess_amount, 0)
            ),
            0
          ),
          :value
        )
    })
    |> order_by(desc: selected_as(:value))
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn row -> %{client: row.client || "Unknown Client", value: row.value} end)
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
