defmodule QuantumBilling.Workers.EInvoiceWorkerTest do
  @moduledoc """
  Registering an invoice with the Invoice Registration Portal, which had no
  test at all.

  What matters here is not the happy path — that is the IRP client's job — but
  the three ways this worker must refuse to act: an invoice that has gone, an
  invoice already carrying an IRN, and a job with nothing to work on. A
  duplicate registration is a compliance problem rather than a harmless repeat,
  so "already registered" has to end the job rather than retry it.
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Settings
  alias QuantumBilling.Workers.EInvoiceWorker

  setup do
    {:ok, _organization} =
      Settings.update_section(
        Settings.get_organization(),
        %{
          "company_name" => "Quantum Billing Tech",
          "gstin" => "27AABCQ9999Q1Z5",
          "pan" => "AABCQ9999Q",
          "state" => "Maharashtra (27)",
          "address" => "Unit 401, Tech Park",
          "city" => "Mumbai",
          "pincode" => "400051"
        },
        :general
      )

    :ok
  end

  # With a line on it, because an invoice with none is not a reportable supply
  # — see the item-less test below.
  defp invoice(attrs \\ %{}) do
    invoice = bare_invoice(attrs)

    Repo.insert!(%InvoiceItem{
      invoice_id: invoice.id,
      description: "Consulting",
      hsn_sac: "998313",
      quantity: 2,
      unit: "Nos",
      rate: 5_000,
      tax_rate: 18,
      amount: 10_000,
      position: 0
    })

    Repo.preload(invoice, :items, force: true)
  end

  defp bare_invoice(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_number: "INV-#{System.unique_integer([:positive])}",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra (27)",
          company_state: "Maharashtra (27)",
          company_name: "Quantum Billing Tech",
          company_gstin: "27AABCQ9999Q1Z5",
          client_name: "Acme Traders",
          client_gstin: "27AABCA1234A1Z5",
          client_billing_address: "1 Main Street, Mumbai",
          client_city: "Mumbai",
          client_pincode: "400001",
          client_state: "Maharashtra (27)",
          total_items: 1,
          taxable_value: 10_000,
          cgst_amount: 900,
          sgst_amount: 900,
          grand_total: 11_800
        },
        attrs
      )
    )
  end

  defp run(args), do: EInvoiceWorker.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 5})

  describe "perform/1" do
    test "registers an invoice that has not been registered" do
      invoice = invoice()

      assert :ok = run(%{"invoice_id" => invoice.id})

      registered = Repo.get!(Invoice, invoice.id)
      assert registered.status == "E-Invoice Generated"
      assert is_binary(registered.irn) and registered.irn != ""
      assert registered.ack_number
      assert registered.signed_qr_code
    end

    test "does nothing for an invoice that already carries an IRN" do
      invoice = invoice(%{irn: "already-registered-irn", status: "E-Invoice Generated"})

      # A second click, or a retry whose first reply was lost. Asking the
      # portal again would register the same invoice twice.
      assert :ok = run(%{"invoice_id" => invoice.id})

      assert Repo.get!(Invoice, invoice.id).irn == "already-registered-irn"
    end

    test "discards a job for an invoice that no longer exists" do
      # Retrying cannot bring it back, so this must not consume five attempts.
      assert :discard = run(%{"invoice_id" => 0})
    end

    test "discards a job with no invoice to work on" do
      assert :discard = run(%{})
      assert :discard = run(%{"something_else" => 1})
    end

    test "refuses an invoice with no line items instead of crashing on it" do
      invoice = bare_invoice()

      # `EInvoice.validate/2` passed this: its items check guarded on
      # `is_list/1`, which an empty list satisfies, so it found no line missing
      # an HSN and reported nothing wrong. The invoice then reached the QR
      # builder, which called `hd([])` and raised `ArgumentError` — inside a
      # job that retried the same crash five times over half an hour.
      assert {:error, message} = run(%{"invoice_id" => invoice.id})
      assert message =~ "no line items"

      assert Repo.get!(Invoice, invoice.id).status == "E-Invoice Failed"
      refute Repo.get!(Invoice, invoice.id).irn
    end

    test "refuses an invoice the seller cannot yet report" do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"company_name" => "Quantum Billing Tech", "address" => nil},
          :general
        )

      invoice = invoice()

      # Submitting to the IRP cannot be taken back, so this path has to be at
      # least as careful as the XML download — which already refused this.
      assert {:error, message} = run(%{"invoice_id" => invoice.id})
      assert message =~ "address is missing"
      refute Repo.get!(Invoice, invoice.id).irn
    end
  end

  describe "backoff/1" do
    test "spreads the attempts over hours, not minutes" do
      delays =
        for attempt <- 1..4 do
          EInvoiceWorker.backoff(%Oban.Job{attempt: attempt})
        end

      # 1, 4, 9, 16 minutes. An IRP outage is measured in hours, and polling it
      # every few seconds through one is useless and rude.
      assert delays == [60, 240, 540, 960]
      assert delays == Enum.sort(delays)
    end
  end

  describe "Invoices.queue_einvoice/1" do
    test "queues the job and marks the invoice pending" do
      invoice = invoice()

      assert {:ok, :queued} = Invoices.queue_einvoice(invoice)
    end

    test "refuses to queue a second registration for the same invoice" do
      invoice = invoice(%{irn: "already-registered-irn"})

      assert {:ok, :already_registered} = Invoices.queue_einvoice(invoice)
    end
  end
end
