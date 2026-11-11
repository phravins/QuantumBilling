defmodule QuantumBilling.Reports do
  @moduledoc """
  Report figures for the Dashboard and the CSV export.

  Every figure is computed by the database from one filtered invoice query, so
  the filters move every panel together. Money is integer paise.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  @doc "Runs `fun` over the filtered rows as a stream, inside a transaction."
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

  # The query behind every report, with `filters` applied.
  defp query(filters) when is_map(filters) do
    # Binned invoices are excluded from every report.
    Invoice.kept()
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

  # Same rule as to_row/1, in SQL.
  @tax_type_sql """
  CASE
    WHEN tax_regime = 'vat' THEN 'VAT'
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
      taxable_value: type(coalesce(sum(i.taxable_value), 0), :integer),
      cgst: type(coalesce(sum(i.cgst_amount), 0), :integer),
      sgst: type(coalesce(sum(i.sgst_amount), 0), :integer),
      igst: type(coalesce(sum(i.igst_amount), 0), :integer),
      cess: type(coalesce(sum(i.cess_amount), 0), :integer)
    })
    |> Repo.all()
    |> Map.new(&{&1.tax_type, &1})
  end

  # VAT invoices, totalled per rate from each invoice's snapshotted breakdown.
  defp vat_rate_totals(filters) do
    filters
    |> query()
    |> where([i], i.tax_regime == "vat")
    |> join(:inner, [i], b in fragment("jsonb_array_elements(?)", i.tax_breakdown), on: true)
    |> group_by([_i, b], [
      fragment("?->>'name'", b.value),
      fragment("COALESCE((?->>'rate_bp')::int, 0)", b.value)
    ])
    |> select([_i, b], %{
      name: fragment("?->>'name'", b.value),
      rate_bp: fragment("COALESCE((?->>'rate_bp')::int, 0)", b.value),
      taxable: type(fragment("COALESCE(SUM((?->>'taxable')::bigint), 0)", b.value), :integer),
      tax: type(fragment("COALESCE(SUM((?->>'tax')::bigint), 0)", b.value), :integer)
    })
    |> Repo.all()
  end

  defp tax_rows_from(totals_by_type, vat_rates) do
    rows =
      [
        aggregated_tax_row(totals_by_type["CGST + SGST"], "CGST + SGST", :intra),
        aggregated_tax_row(totals_by_type["IGST"], "IGST", :inter),
        aggregated_tax_row(totals_by_type["CESS"], "CESS", :cess)
      ]
      |> Enum.reject(&is_nil/1)

    rows = rows ++ vat_rows(vat_rates)

    rows ++ [totals_row(rows)]
  end

  # One row per VAT rate, highest rate first.
  defp vat_rows(rates) do
    rates
    |> Enum.sort_by(&{-&1.rate_bp, &1.name || ""})
    |> Enum.map(fn rate ->
      %{
        label: "VAT · " <> (rate.name || "No VAT"),
        taxable_value: rate.taxable,
        cgst: nil,
        sgst: nil,
        igst: nil,
        vat: rate.tax,
        total_tax: rate.tax,
        total?: false
      }
    end)
  end

  defp aggregated_tax_row(nil, _label, _kind), do: nil

  defp aggregated_tax_row(totals, label, kind) do
    %{
      label: label,
      taxable_value: totals.taxable_value,
      cgst: if(kind == :intra, do: totals.cgst),
      sgst: if(kind == :intra, do: totals.sgst),
      igst: if(kind == :inter, do: totals.igst),
      vat: nil,
      total_tax: totals.cgst + totals.sgst + totals.igst + totals.cess,
      total?: false
    }
  end

  @doc "Whether any invoice matching `filters` was raised under VAT."
  def any_vat?(filters) when is_map(filters),
    do: filters |> query() |> where([i], i.tax_regime == "vat") |> Repo.exists?()

  @doc "One row per tax type (and VAT rate), then a totals row. `nil` means not applicable."
  def tax_rows(filters) when is_map(filters),
    do: tax_rows_from(tax_type_totals(filters), vat_rate_totals(filters))

  @doc "The `limit` clients with the highest invoice value, highest first."
  def top_client_totals(filters, limit \\ 5) when is_map(filters) do
    filters
    |> query()
    |> group_by([i], i.client_name)
    |> select([i], %{
      client: i.client_name,
      value:
        selected_as(
          type(
            coalesce(
              sum(
                coalesce(i.taxable_value, 0) + coalesce(i.cgst_amount, 0) +
                  coalesce(i.sgst_amount, 0) + coalesce(i.igst_amount, 0) +
                  coalesce(i.cess_amount, 0) + coalesce(i.vat_amount, 0)
              ),
              0
            ),
            :integer
          ),
          :value
        )
    })
    |> order_by(desc: selected_as(:value))
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn row -> %{client: row.client || "Unknown Client", value: row.value} end)
  end

  # An invoice as an export row. Its tax type follows the same rule as @tax_type_sql.
  defp to_row(%Invoice{} = invoice) do
    tax_type =
      cond do
        Invoice.vat?(invoice) ->
          "VAT"

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
      cess: invoice.cess_amount || 0,
      vat: invoice.vat_amount || 0,
      tax_breakdown: invoice.tax_breakdown || [],
      tax_number: invoice.client_tax_number,
      round_off: invoice.round_off || 0,
      custom_fields: invoice.custom_fields || %{}
    }
  end

  defp totals_row(rows) do
    %{
      label: "Total",
      taxable_value: sum_by(rows, & &1.taxable_value),
      cgst: sum_present(rows, & &1.cgst),
      sgst: sum_present(rows, & &1.sgst),
      igst: sum_present(rows, & &1.igst),
      vat: sum_present(rows, & &1.vat),
      total_tax: sum_by(rows, & &1.total_tax),
      total?: true
    }
  end

  # Only columns used by some row are totalled.
  defp sum_present(rows, fun) do
    case Enum.filter(rows, &(fun.(&1) != nil)) do
      [] -> nil
      present -> sum_by(present, fun)
    end
  end

  defp sum_by(rows, fun), do: Enum.reduce(rows, 0, fn row, acc -> acc + fun.(row) end)

  @doc """
  Resolves a named range to `{from, to}`, or `{nil, nil}` for "All Time".
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
end
