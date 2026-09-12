defmodule QuantumBilling.EWayBillsTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices.Invoice

  test "generate_e_way_bill/2 generates EWB number and updates invoice" do
    invoice = %Invoice{
      id: 101,
      invoice_number: "INV-9901",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_name: "Acme India Pvt Ltd",
      client_gstin: "27AAAAA0000A1Z5",
      taxable_value: 100_000,
      grand_total: 118_000
    }

    invoice = Repo.insert!(invoice)

    assert {:ok, updated} =
             EWayBills.generate_e_way_bill(invoice, %{
               "distance_km" => "180",
               "vehicle_number" => "MH04CD5678"
             })

    assert updated.ewb_number =~ ~r/^1910/
    assert updated.distance_km == 180
    assert updated.vehicle_number == "MH04CD5678"
  end
end
