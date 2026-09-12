defmodule QuantumBilling.CreditNotesTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Clients.Client

  test "create_credit_note_for_invoice/2 creates a Credit Note linked to invoice" do
    client = %Client{name: "Epsilon LLC", email: "epsilon@example.com"}
    client = Repo.insert!(client)

    invoice = %Invoice{
      id: 401,
      invoice_number: "INV-9905",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_id: client.id,
      client_name: client.name,
      taxable_value: 10000,
      grand_total: 11800
    }

    invoice = Repo.insert!(invoice)

    assert {:ok, cn} =
             CreditNotes.create_credit_note_for_invoice(invoice, %{
               "note_type" => "Credit",
               "reason" => "Discount applied after issue",
               "grand_total" => Decimal.new("11800.00")
             })

    assert cn.note_number =~ ~r/^CN-INV-9905-/
    assert cn.note_type == "Credit"
    assert cn.invoice_id == invoice.id
    assert cn.client_id == client.id
  end
end
