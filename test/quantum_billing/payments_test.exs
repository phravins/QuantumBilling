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

    _invoice = Repo.insert!(invoice)

    webhook_payload = %{
      "event" => "payment_link.paid",
      "payload" => %{
        "payment_link" => %{
          "entity" => %{
            "id" => "plink_test123",
            "reference_id" => "INV-9903",
            "amount_paid" => 4_500_000,
            "currency" => "INR"
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

  describe "a payment that does not match the invoice" do
    setup do
      invoice =
        Repo.insert!(%Invoice{
          invoice_number: "INV-9950",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_name: "Delta Ltd",
          grand_total: 10_000,
          status: "Draft",
          razorpay_payment_link_id: "plink_issued"
        })

      %{invoice: invoice}
    end

    defp link_paid(attrs) do
      entity =
        Map.merge(
          %{
            "id" => "plink_issued",
            "reference_id" => "INV-9950",
            "amount_paid" => 1_000_000,
            "currency" => "INR"
          },
          attrs
        )

      %{
        "event" => "payment_link.paid",
        "payload" => %{
          "payment_link" => %{"entity" => entity},
          "payment" => %{"entity" => %{"id" => "pay_9950"}}
        }
      }
    end

    defp captured(attrs) do
      entity = Map.merge(%{"id" => "pay_c9950", "currency" => "INR"}, attrs)
      %{"event" => "payment.captured", "payload" => %{"payment" => %{"entity" => entity}}}
    end

    test "the full amount through the issued link marks it paid", %{invoice: invoice} do
      assert {:ok, %Invoice{status: "Paid"}} = Payments.process_razorpay_webhook(link_paid(%{}))
      assert Repo.get(Invoice, invoice.id).razorpay_payment_id == "pay_9950"
    end

    test "an under-payment is rejected and audited", %{invoice: invoice} do
      assert {:error, :amount_mismatch} =
               Payments.process_razorpay_webhook(link_paid(%{"amount_paid" => 100}))

      assert Repo.get(Invoice, invoice.id).status == "Draft"

      assert Repo.exists?(
               from l in QuantumBilling.Audit.AuditLog,
                 where: l.action == "payment_rejected" and l.resource_id == ^to_string(invoice.id)
             )
    end

    test "a payment with no amount is rejected", %{invoice: invoice} do
      assert {:error, :amount_mismatch} =
               Payments.process_razorpay_webhook(link_paid(%{"amount_paid" => nil}))

      assert Repo.get(Invoice, invoice.id).status == "Draft"
    end

    test "the wrong currency is rejected", %{invoice: invoice} do
      assert {:error, :currency_mismatch} =
               Payments.process_razorpay_webhook(link_paid(%{"currency" => "USD"}))

      assert Repo.get(Invoice, invoice.id).status == "Draft"
    end

    test "a link other than the one issued is rejected", %{invoice: invoice} do
      assert {:error, :unknown_payment_link} =
               Payments.process_razorpay_webhook(link_paid(%{"id" => "plink_someone_else"}))

      assert Repo.get(Invoice, invoice.id).status == "Draft"
    end

    test "a small captured payment naming the invoice in its description is rejected",
         %{invoice: invoice} do
      payload = captured(%{"amount" => 100, "description" => "for INV-9950"})

      assert {:error, :amount_mismatch} = Payments.process_razorpay_webhook(payload)
      assert Repo.get(Invoice, invoice.id).status == "Draft"
    end

    test "a full captured payment is matched by its notes", %{invoice: invoice} do
      payload = captured(%{"amount" => 1_000_000, "notes" => %{"invoice_number" => "INV-9950"}})

      assert {:ok, %Invoice{status: "Paid"}} = Payments.process_razorpay_webhook(payload)
      assert Repo.get(Invoice, invoice.id).razorpay_payment_id == "pay_c9950"
    end
  end
end
