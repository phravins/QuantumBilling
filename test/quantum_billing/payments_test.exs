defmodule QuantumBilling.PaymentsTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Payments
  alias QuantumBilling.Invoices.Invoice

  test "generate_payment_link/1 creates razorpay link and updates invoice" do
    invoice = %Invoice{
      id: 201,
      invoice_number: "INV-9902",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_name: "Beta Corp",
      grand_total: 25000
    }

    invoice = Repo.insert!(invoice)

    assert {:ok, updated} = Payments.generate_payment_link(invoice)
    assert updated.razorpay_payment_link_id =~ ~r/^plink_/
    assert updated.razorpay_payment_url =~ ~r/rzp.io/
  end

  test "process_razorpay_webhook/1 reconciles invoice and marks status Paid" do
    invoice = %Invoice{
      id: 202,
      invoice_number: "INV-9903",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_name: "Gamma Tech",
      grand_total: 45000,
      status: "Draft"
    }

    invoice = Repo.insert!(invoice)

    webhook_payload = %{
      "event" => "payment_link.paid",
      "payload" => %{
        "payment_link" => %{
          "entity" => %{
            "id" => "plink_test123",
            "reference_id" => "INV-9903"
          }
        },
        "payment" => %{
          "entity" => %{
            "id" => "pay_test999"
          }
        }
      }
    }

    assert {:ok, updated} = Payments.process_razorpay_webhook(webhook_payload)
    assert updated.status == "Paid"
    assert updated.razorpay_payment_id == "pay_test999"
  end
end
