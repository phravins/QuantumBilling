defmodule QuantumBilling.InvoiceNotifierTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Invoices.Invoice

  test "build_email/2 addresses the invoice email and attaches the document" do
    invoice = %Invoice{
      id: 1,
      invoice_number: "INV-8801",
      company_name: "Quantum Billing Tech Solutions",
      grand_total: 50000,
      invoice_date: ~D[2026-03-01],
      due_date: ~D[2026-03-31]
    }

    assert {:ok, email} = InvoiceNotifier.build_email("client@example.com", invoice)

    assert email.to == [{"", "client@example.com"}]
    assert email.subject == "Tax Invoice INV-8801 from Quantum Billing Tech Solutions"
    assert [%Swoosh.Attachment{filename: "INV-8801." <> _}] = email.attachments
  end
end
