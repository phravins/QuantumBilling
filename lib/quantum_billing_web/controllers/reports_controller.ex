defmodule QuantumBillingWeb.ReportsController do
  @moduledoc """
  Report downloads linked from the Dashboard, using the same filters as its tax summary.
  """
  use QuantumBillingWeb, :controller

  plug QuantumBillingWeb.Plugs.RecordExport, "report export" when action in [:export]

  alias QuantumBilling.CustomFields
  alias QuantumBilling.Money
  alias QuantumBilling.Reports
  alias QuantumBillingWeb.CustomFieldComponents

  @headers ["Tax Type", "Taxable Value", "CGST", "SGST", "IGST", "Total Tax"]
  @sales_register_headers [
    "Date",
    "Invoice Number",
    "Client",
    "GSTIN",
    "Status",
    "Tax Type",
    "Taxable Value",
    "CGST",
    "SGST",
    "IGST",
    "Cess",
    "Total Tax",
    "Grand Total"
  ]

  @doc "Streams the filtered report as CSV, straight from a database cursor."
  def export(conn, params) do
    filters = filters_from(params)

    if filters.report_type == "Sales Register" do
      stream_sales_register(conn, filters)
    else
      tax_rows = filters |> Reports.aggregate() |> Map.fetch!(:tax_rows)
      vat? = Enum.any?(tax_rows, &(&1.vat != nil))

      send_download(conn, {:binary, to_csv(headers(vat?), tax_summary_rows(tax_rows, vat?))},
        filename: filename(if(vat?, do: "tax-summary", else: "gst-tax-summary"), filters)
      )
    end
  end

  # The invoice's own fields follow the fixed columns, one per active field.
  defp stream_sales_register(conn, filters) do
    definitions = CustomFields.active_definitions("invoice")
    vat? = Reports.any_vat?(filters)

    headers =
      sales_register_headers(vat?) ++ CustomFieldComponents.export_headers(definitions)

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename("gst-sales-register", filters)}")
      )
      |> send_chunked(200)

    {:ok, conn} =
      Reports.stream_rows(filters, fn rows ->
        rows
        |> Stream.map(&csv_line(sales_register_row(&1, definitions, vat?)))
        |> Enum.reduce_while(chunk!(conn, csv_line(headers)), fn line, conn ->
          case chunk(conn, line) do
            {:ok, conn} -> {:cont, conn}
            # The browser went away mid-download.
            {:error, :closed} -> {:halt, conn}
          end
        end)
      end)

    conn
  end

  defp chunk!(conn, data) do
    {:ok, conn} = chunk(conn, data)
    conn
  end

  defp filters_from(params) do
    Reports.default_filters()
    |> Map.put(:date_range, param(params, "date_range", "This Year"))
    |> Map.put(:report_type, param(params, "report_type", "All Reports"))
    |> Map.put(:client, param(params, "client", "All Clients"))
    |> Map.put(:status, param(params, "status", "All Status"))
    |> Map.put(:gstin, param(params, "gstin", ""))
  end

  defp param(params, key, default) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _missing_or_nested -> default
    end
  end

  # A VAT column only when some invoice charged VAT, so GST exports are unchanged.
  defp headers(false), do: @headers
  defp headers(true), do: List.insert_at(@headers, -2, "VAT")

  defp sales_register_headers(false), do: @sales_register_headers

  defp sales_register_headers(true) do
    @sales_register_headers
    |> List.replace_at(3, "GSTIN / VAT No.")
    |> List.insert_at(-3, "VAT")
  end

  defp tax_summary_rows(tax_summary, vat?) do
    Enum.map(tax_summary, fn row ->
      [
        row.label,
        amount(row.taxable_value),
        amount(row.cgst),
        amount(row.sgst),
        amount(row.igst)
      ] ++ if(vat?, do: [amount(row.vat)], else: []) ++ [amount(row.total_tax)]
    end)
  end

  defp sales_register_row(row, definitions, vat?) do
    vat = Map.get(row, :vat, 0)
    total_tax = row.cgst + row.sgst + row.igst + row.cess + vat
    # Round off included, so the column matches the invoice's own total.
    grand_total = row.taxable_value + total_tax + Map.get(row, :round_off, 0)

    [
      QuantumBillingWeb.Format.format_date(row.date),
      to_string(row[:number] || ""),
      row.client,
      tax_number(row, vat?),
      row.status,
      row.tax_type,
      amount(row.taxable_value),
      amount(row.cgst),
      amount(row.sgst),
      amount(row.igst),
      amount(row.cess)
    ] ++
      if(vat?, do: [amount(vat)], else: []) ++
      [
        amount(total_tax),
        amount(grand_total)
      ] ++ CustomFieldComponents.export_cells(definitions, Map.get(row, :custom_fields))
  end

  defp tax_number(%{gstin: gstin} = row, true) when gstin in [nil, ""],
    do: Map.get(row, :tax_number) || ""

  defp tax_number(row, _vat?), do: row.gstin

  # Plain rupee numbers, from paise, so a spreadsheet can sum them.
  defp amount(nil), do: ""
  defp amount(paise), do: Money.to_input(paise)

  defp filename(prefix, filters) do
    slug =
      filters.date_range
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")

    "#{prefix}-#{slug}.csv"
  end

  defp to_csv(headers, rows) do
    Enum.map_join([headers | rows], "", &csv_line/1)
  end

  defp csv_line(fields), do: QuantumBillingWeb.CSV.line(fields)
end
