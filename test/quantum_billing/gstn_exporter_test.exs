defmodule QuantumBilling.GSTNExporterTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Compliance.GSTNExporter
  alias QuantumBilling.Invoices.Invoice

  test "generate_gstr1_json/1 constructs valid GSTN JSON structure" do
    invoice = %Invoice{
      id: 301,
      invoice_number: "INV-9904",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "27-Maharashtra",
      company_state: "27-Maharashtra",
      client_name: "Delta Retailers",
      client_gstin: "27CCCDE1234F1Z5",
      taxable_value: 50000,
      cgst_amount: 4500,
      sgst_amount: 4500,
      grand_total: 59000
    }

    Repo.insert!(invoice)

    json = GSTNExporter.generate_gstr1_json("032026")

    assert json["version"] == "GSTR1_v3.1"
    assert json["fp"] == "032026"
    assert is_list(json["b2b"])
    assert is_list(json["b2cs"])
    assert is_map(json["hsn"])
  end
end
