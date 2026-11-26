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
      grand_total: 2_500_000
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
      grand_total: 4_500_000,
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
          grand_total: 1_000_000,
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

    test "a payment far above the total is rejected and audited", %{invoice: invoice} do
      assert {:error, :amount_mismatch} =
               Payments.process_razorpay_webhook(link_paid(%{"amount_paid" => 999_999_999}))

      assert Repo.get(Invoice, invoice.id).status == "Draft"

      assert Repo.exists?(
               from l in QuantumBilling.Audit.AuditLog,
                 where: l.action == "payment_rejected" and l.resource_id == ^to_string(invoice.id)
             )
    end

    test "a captured payment far above the total is rejected", %{invoice: invoice} do
      payload = captured(%{"amount" => 999_999_999, "notes" => %{"invoice_number" => "INV-9950"}})

      assert {:error, :amount_mismatch} = Payments.process_razorpay_webhook(payload)
      assert Repo.get(Invoice, invoice.id).status == "Draft"
    end

    test "a gateway fee the customer paid, up to 5% over, is accepted", %{invoice: invoice} do
      assert {:ok, %Invoice{status: "Paid"}} =
               Payments.process_razorpay_webhook(link_paid(%{"amount_paid" => 1_050_000}))

      assert Repo.get(Invoice, invoice.id).status == "Paid"
    end

    test "just past 5% over is rejected", %{invoice: invoice} do
      assert {:error, :amount_mismatch} =
               Payments.process_razorpay_webhook(link_paid(%{"amount_paid" => 1_050_001}))

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

  describe "a cancelled invoice" do
    import Swoosh.TestAssertions

    alias QuantumBilling.Notifications.Notification

    setup do
      invoice =
        Repo.insert!(%Invoice{
          invoice_number: "INV-9960",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_name: "Epsilon Ltd",
          client_email: "accounts@epsilon.test",
          grand_total: 1_000_000,
          status: "Cancelled",
          razorpay_payment_link_id: "plink_old"
        })

      %{invoice: invoice}
    end

    defp old_link_paid do
      %{
        "event" => "payment_link.paid",
        "payload" => %{
          "payment_link" => %{
            "entity" => %{
              "id" => "plink_old",
              "reference_id" => "INV-9960",
              "amount_paid" => 1_000_000,
              "currency" => "INR"
            }
          },
          "payment" => %{"entity" => %{"id" => "pay_9960"}}
        }
      }
    end

    test "a payment through its old link is refused, audited and raised", %{invoice: invoice} do
      assert {:error, :invoice_cancelled} = Payments.process_razorpay_webhook(old_link_paid())

      assert %Invoice{status: "Cancelled", razorpay_payment_id: nil} =
               Repo.get(Invoice, invoice.id)

      assert Repo.exists?(
               from l in QuantumBilling.Audit.AuditLog,
                 where: l.action == "payment_rejected" and l.resource_id == ^to_string(invoice.id)
             )

      assert %Notification{severity: "error", title: title, body: body} =
               Repo.get_by(Notification, dedupe_key: "payment_rejected:pay_9960")

      assert title == "Payment received for cancelled INV-9960"
      assert body =~ "Refund payment pay_9960"

      assert_no_email_sent()
    end

    test "a captured payment naming it is refused", %{invoice: invoice} do
      payload = %{
        "event" => "payment.captured",
        "payload" => %{
          "payment" => %{
            "entity" => %{
              "id" => "pay_c9960",
              "amount" => 1_000_000,
              "currency" => "INR",
              "notes" => %{"invoice_number" => "INV-9960"}
            }
          }
        }
      }

      assert {:error, :invoice_cancelled} = Payments.process_razorpay_webhook(payload)
      assert Repo.get(Invoice, invoice.id).status == "Cancelled"
    end

    test "reconcile_payment/3 will not mark it paid", %{invoice: invoice} do
      assert {:error, :invoice_cancelled} = Payments.reconcile_payment(invoice, "pay_direct")
      assert Repo.get(Invoice, invoice.id).status == "Cancelled"
    end

    test "a stale copy loaded before the cancel is not marked paid", %{invoice: invoice} do
      stale = %{invoice | status: "Draft"}

      assert {:error, :invoice_cancelled} = Payments.reconcile_payment(stale, "pay_stale")
      assert Repo.get(Invoice, invoice.id).status == "Cancelled"
    end

    test "gets no new payment link", %{invoice: invoice} do
      refute Payments.open_for_payment?(invoice)
      assert {:error, :cancelled} = Payments.generate_payment_link(invoice)
    end
  end

  describe "another currency" do
    setup do
      invoice =
        Repo.insert!(%Invoice{
          invoice_number: "INV-AED-1",
          invoice_date: ~D[2026-03-01],
          client_name: "Gulf Traders",
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          currency: "AED",
          grand_total: 105_000
        })

      %{invoice: invoice}
    end

    test "gets no Razorpay link", %{invoice: invoice} do
      refute Payments.online_payable?(invoice)
      assert {:error, :unsupported_currency} = Payments.generate_payment_link(invoice)
      assert is_nil(Repo.get(Invoice, invoice.id).razorpay_payment_link_id)
      assert Payments.unavailable_message(invoice) == "Online payment not available for AED"
    end

    test "gets no UPI QR", %{invoice: invoice} do
      assert {:error, :unsupported_currency} = QuantumBilling.Payments.QRCode.upi_uri(invoice)
    end
  end

  describe "concurrency and duplicate reference handling" do
    test "recovers existing payment link when duplicate reference error occurs" do
      invoice =
        Repo.insert!(%Invoice{
          invoice_number: "INV-DUP-1",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_name: "Duplicate Corp",
          grand_total: 500_000,
          currency: "INR",
          status: "Draft"
        })

      System.put_env("RAZORPAY_KEY_ID", "rzp_test_key")
      System.put_env("RAZORPAY_KEY_SECRET", "rzp_test_secret")
      on_exit(fn -> System.delete_env("RAZORPAY_KEY_ID") end)
      on_exit(fn -> System.delete_env("RAZORPAY_KEY_SECRET") end)

      previous = Req.default_options()
      Req.default_options(plug: {Req.Test, __MODULE__})
      on_exit(fn -> Req.default_options(previous) end)

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/payment_links"} ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{
              "error" => %{
                "code" => "BAD_REQUEST_ERROR",
                "description" => "An existing reference id has been passed",
                "field" => "reference_id"
              }
            })

          {"GET", "/v1/payment_links"} ->
            Req.Test.json(conn, %{
              "payment_links" => [
                %{
                  "id" => "plink_recovered_999",
                  "short_url" => "https://rzp.io/i/recovered999",
                  "reference_id" => "INV-DUP-1",
                  "status" => "created"
                }
              ]
            })
        end
      end)

      assert {:ok, updated} = Payments.generate_payment_link(invoice)
      assert updated.razorpay_payment_link_id == "plink_recovered_999"
      assert updated.razorpay_payment_url == "https://rzp.io/i/recovered999"
      assert Repo.get(Invoice, invoice.id).razorpay_payment_link_id == "plink_recovered_999"
    end

    test "concurrent generate_payment_link calls serialize and create only one link" do
      invoice =
        Repo.insert!(%Invoice{
          invoice_number: "INV-CONCUR-1",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_name: "Concurrent Corp",
          grand_total: 750_000,
          currency: "INR",
          status: "Draft"
        })

      test_pid = self()

      task1 =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(QuantumBilling.Repo, test_pid, self())
          Payments.generate_payment_link(invoice)
        end)

      task2 =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(QuantumBilling.Repo, test_pid, self())
          Payments.generate_payment_link(invoice)
        end)

      res1 = Task.await(task1)
      res2 = Task.await(task2)

      assert {:ok, updated1} = res1
      assert {:ok, updated2} = res2
      assert updated1.razorpay_payment_link_id == updated2.razorpay_payment_link_id
      assert updated1.razorpay_payment_url == updated2.razorpay_payment_url
    end
  end
end
