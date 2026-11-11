defmodule QuantumBillingWeb.ClientImportTemplateController do
  @moduledoc """
  A CSV to fill in for the client import: the headers the import recognises,
  for this business's tax regime and its active custom fields, and one example
  row to overwrite.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.CustomFields
  alias QuantumBillingWeb.CSV

  @gst [
    {"Client name", "Acme Traders Pvt Ltd"},
    {"Client type", "Registered Business"},
    {"GSTIN", "33AAACA1234A1Z5"},
    {"PAN", "AAACA1234A"},
    {"Email", "accounts@acme.example"},
    {"Phone", "9876543210"},
    {"Address line 1", "12 Anna Salai"},
    {"Address line 2", "Teynampet"},
    {"City", "Chennai"},
    {"State", "Tamil Nadu"},
    {"PIN code", "600018"},
    {"Business type", "Private Limited"},
    {"Category", "Customer"},
    {"Payment terms (days)", "30"},
    {"Credit limit", "100000"},
    {"Opening balance", "0"},
    {"Notes", ""}
  ]

  @vat [
    {"Client name", "Acme Trading LLC"},
    {"Client type", "Registered Business"},
    {"Country", "AE"},
    {"Tax number", "100123456700003"},
    {"Email", "accounts@acme.example"},
    {"Phone country code", "+971"},
    {"Phone", "501234567"},
    {"Address line 1", "Office 1204, Bay Square"},
    {"Address line 2", "Business Bay"},
    {"City", "Dubai"},
    {"State", ""},
    {"Postal code", ""},
    {"Business type", "Private Limited"},
    {"Category", "Customer"},
    {"Payment terms (days)", "30"},
    {"Credit limit", "50000"},
    {"Opening balance", "0"},
    {"Notes", ""}
  ]

  def show(conn, _params) do
    columns = if conn.assigns.current_scope.tax_regime == "vat", do: @vat, else: @gst
    custom = for d <- CustomFields.active_definitions("client"), do: {d.label, ""}
    {headers, example} = Enum.unzip(columns ++ custom)

    send_download(conn, {:binary, CSV.line(headers) <> CSV.line(example)},
      filename: "clients-import-template.csv",
      content_type: "text/csv"
    )
  end
end
