defmodule QuantumBilling.InvoiceNotifierTest do
  use QuantumBilling.DataCase, async: true
  import Swoosh.TestAssertions

  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Mail
  alias QuantumBillingWeb.InvoiceDocument

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

  describe "deliver_test_invoice/2" do
    test "addresses and words itself as a test" do
      assert {:ok, _result} =
               InvoiceNotifier.deliver_test_invoice("me@example.com", InvoiceDocument.sample())

      # Not the customer-facing subject. The one message you read before going
      # live should not be indistinguishable from the one customers get.
      assert_email_sent(fn email ->
        assert email.subject =~ "Test invoice"
        refute email.subject =~ "INV-0042"
        assert email.text_body =~ "Nobody has been billed"

        # The design itself, which is the thing being tested.
        assert [attachment] = email.attachments
        assert attachment.filename in ["test-invoice.pdf", "test-invoice.html"]
      end)
    end

    test "is recorded in the delivery ledger like everything else" do
      before = length(Mail.list_recent_deliveries(50))

      assert {:ok, _result} =
               InvoiceNotifier.deliver_test_invoice("me@example.com", InvoiceDocument.sample())

      deliveries = Mail.list_recent_deliveries(50)
      assert length(deliveries) == before + 1

      recorded = hd(deliveries)
      assert recorded.to_email == "me@example.com"
      assert recorded.kind == "test"
      assert recorded.status == "sent"
    end

    test "refuses an address it cannot send to" do
      assert {:error, :invalid_recipient} =
               InvoiceNotifier.deliver_test_invoice("not an address", InvoiceDocument.sample())

      assert_no_email_sent()
    end
  end
end
