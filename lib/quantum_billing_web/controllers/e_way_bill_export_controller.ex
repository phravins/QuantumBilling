defmodule QuantumBillingWeb.EWayBillExportController do
  @moduledoc """
  The E-Way Bills list, as a CSV download.

  The Export button on that page used to link to `/reports/export` with
  `report_type=E-Way+Bills`. `Reports` has no such report type, so the
  parameter fell through its catch-all clause and the user was quietly handed a
  GST tax summary named `gst-tax-summary-this-year.csv` instead — a wrong file
  that looks like a working download.

  The filters travel in the query string so the file matches what was on
  screen, exactly as `ReportsController` does it. Unlike the sales register
  this is not chunked: an e-way bill exists only for a consignment in transit,
  so the row count is bounded by how much is on the road, not by how long the
  business has been trading.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.EWayBills

  @headers [
    "EWB Number",
    "Document Number",
    "Issued On",
    "Valid Until",
    "Consignee",
    "From",
    "To",
    "Value",
    "Distance (km)",
    "Mode",
    "Vehicle",
    "Transporter",
    "Status"
  ]

  def export(conn, params) do
    rows =
      EWayBills.export_rows(
        search: param(params, "q", ""),
        status: param(params, "status", "All Status"),
        sort_field: :issued_on,
        sort_dir: :desc
      )

    send_download(conn, {:binary, to_csv(@headers, Enum.map(rows, &csv_row/1))},
      filename: "e-way-bills.csv"
    )
  end

  defp param(params, key, default) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _missing_or_nested -> default
    end
  end

  defp csv_row(row) do
    [
      to_string(row.ewb_no),
      to_string(row.document_no),
      QuantumBillingWeb.Format.format_date(row.issued_on),
      valid_until(row.valid_until),
      to_string(row.to_party),
      to_string(row.from_place),
      to_string(row.to_place),
      amount(row.value),
      to_string(row.distance_km || ""),
      to_string(row.mode_of_transport || ""),
      to_string(row.vehicle_number || ""),
      to_string(row.transporter_name || ""),
      to_string(row.status)
    ]
  end

  defp valid_until(nil), do: ""

  defp valid_until(%NaiveDateTime{} = valid_until) do
    Calendar.strftime(valid_until, "%d/%m/%Y %H:%M")
  end

  # Plain numbers so a spreadsheet can sum them.
  defp amount(nil), do: ""
  defp amount(%Decimal{} = value), do: Decimal.to_string(Decimal.round(value, 2), :normal)
  defp amount(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp to_csv(headers, rows) do
    Enum.map_join([headers | rows], "", &csv_line/1)
  end

  defp csv_line(fields) do
    Enum.map_join(fields, ",", &escape/1) <> "\r\n"
  end

  defp escape(field) do
    if String.contains?(field, [",", "\"", "\n", "\r"]) do
      ~s("#{String.replace(field, "\"", "\"\"")}")
    else
      field
    end
  end
end
