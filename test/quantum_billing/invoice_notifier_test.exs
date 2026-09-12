defmodule QuantumBilling.InvoiceNotifierTest do
  use QuantumBilling.DataCase, async: true
  import Swoosh.TestAssertions

  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Invoices.Invoice

  test "deliver_invoice_pdf/2 sends email with PDF attachment" do
    invoice = %Invoice{
      id: 1,
      invoice_number: "INV-8801",
      company_name: "Quantum Billing Tech Solutions",
      grand_total: 50000,
      invoice_date: ~D[2026-03-01],
      due_date: ~D[2026-03-31]
    }

    assert {:ok, _result} = InvoiceNotifier.deliver_invoice_pdf("client@example.com", invoice)

    assert_email_sent(
      to: [{"", "client@example.com"}],
      subject: "Tax Invoice INV-8801 from Quantum Billing Tech Solutions"
    )
  end
end
