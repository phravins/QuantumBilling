defmodule QuantumBilling.Workers.EmailWorkerTest do
  use QuantumBilling.DataCase, async: true

  import Swoosh.TestAssertions

  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Mail
  alias QuantumBilling.Workers.EmailWorker

  defp invoice_fixture(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_number: "INV-5001",
          invoice_type: "Tax Invoice",
          invoice_date: ~D[2026-03-01],
          due_date: ~D[2026-03-31],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          company_name: "Quantum Billing Tech",
          client_name: "Acme Corp",
          client_email: "client@example.com",
          grand_total: 11_800
        },
        attrs
      )
    )
  end

  describe "queueing an invoice email" do
    test "records the attempt before anything is sent" do
      invoice = invoice_fixture()

      assert {:ok, delivery} =
               InvoiceNotifier.deliver_invoice_pdf_async("client@example.com", invoice)

      assert delivery.to_email == "client@example.com"
      assert delivery.kind == "invoice"
      assert delivery.subject =~ invoice.invoice_number
      assert delivery.invoice_id == invoice.id
    end

    test "refuses a recipient that is not an address, without queueing anything" do
      invoice = invoice_fixture()

      assert {:error, :invalid_recipient} =
               InvoiceNotifier.deliver_invoice_pdf_async("not-an-address", invoice)

      assert {:error, :invalid_recipient} =
               InvoiceNotifier.deliver_invoice_pdf_async(nil, invoice)

      assert Mail.list_recent_deliveries() == []
    end
  end

  describe "perform/1" do
    test "sends the invoice and marks the delivery sent" do
      invoice = invoice_fixture()
      {:ok, delivery} = Mail.record_queued(%{to_email: "client@example.com", kind: "invoice"})

      assert :ok =
               perform_job(%{"delivery_id" => delivery.id, "invoice_id" => invoice.id}, 1)

      assert_email_sent(to: [{"", "client@example.com"}])

      reloaded = Mail.get_delivery(delivery.id)
      assert reloaded.status == "sent"
      assert reloaded.attempts == 1
      assert reloaded.delivered_at
    end

    test "discards a job whose delivery row is gone" do
      assert :discard = perform_job(%{"delivery_id" => 0, "invoice_id" => 0}, 1)
    end

    test "discards — rather than retries — a job whose invoice no longer exists" do
      {:ok, delivery} = Mail.record_queued(%{to_email: "client@example.com"})

      assert :discard = perform_job(%{"delivery_id" => delivery.id, "invoice_id" => 0}, 1)

      reloaded = Mail.get_delivery(delivery.id)
      assert reloaded.status == "failed"
      assert reloaded.last_error =~ "no longer exists"
    end

    test "a job with nothing to render is discarded" do
      {:ok, delivery} = Mail.record_queued(%{to_email: "client@example.com"})

      assert :discard = perform_job(%{"delivery_id" => delivery.id}, 1)
      assert Mail.get_delivery(delivery.id).status == "failed"
    end
  end

  defp perform_job(args, attempt) do
    EmailWorker.perform(%Oban.Job{
      args: args,
      attempt: attempt,
      max_attempts: 5,
      worker: "QuantumBilling.Workers.EmailWorker"
    })
  end
end
