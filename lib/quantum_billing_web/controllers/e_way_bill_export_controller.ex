defmodule QuantumBillingWeb.EWayBillExportController do
  @moduledoc """
  The E-Way Bills list as CSV, with the on-screen filters from the query string.
  Not chunked: only consignments in transit have bills, so the count stays small.
  """
  use QuantumBillingWeb, :controller

  plug QuantumBillingWeb.GSTOnly, :e_way_bills
  plug QuantumBillingWeb.Plugs.RecordExport, "e-way bill export" when action in [:export]

  alias QuantumBilling.CustomFields
  alias QuantumBilling.EWayBills
  alias QuantumBilling.Money
  alias QuantumBillingWeb.CustomFieldComponents

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
    "Status",
    "Portal"
  ]

  def export(conn, params) do
    rows =
      EWayBills.export_rows(
        search: param(params, "q", ""),
        status: param(params, "status", "All Status"),
        sort_field: :issued_on,
        sort_dir: :desc
      )

    definitions = CustomFields.active_definitions("e_way_bill")
    headers = @headers ++ CustomFieldComponents.export_headers(definitions)

    rows =
      Enum.map(
        rows,
        &(csv_row(&1) ++ CustomFieldComponents.export_cells(definitions, &1.custom_fields))
      )

    send_download(conn, {:binary, to_csv(headers, rows)}, filename: "e-way-bills.csv")
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
      to_string(row.status),
      portal(row.portal_mode)
    ]
  end

  # A demo number in a spreadsheet looks like a filed one; say which it is.
  defp portal("live"), do: "Filed"
  defp portal(_demo), do: "Demo (not filed)"

  defp valid_until(nil), do: ""

  defp valid_until(%NaiveDateTime{} = valid_until) do
    Calendar.strftime(valid_until, "%d/%m/%Y %H:%M")
  end

  # Plain rupee numbers, from paise, so a spreadsheet can sum them.
  defp amount(nil), do: ""
  defp amount(paise), do: Money.to_input(paise)

  defp to_csv(headers, rows) do
    Enum.map_join([headers | rows], "", &csv_line/1)
  end

  defp csv_line(fields), do: QuantumBillingWeb.CSV.line(fields)
end
