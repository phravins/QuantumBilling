defmodule QuantumBillingWeb.PaymentWebhookControllerTest do
  use QuantumBillingWeb.ConnCase, async: false

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.RazorpayClient
  alias QuantumBilling.RateLimiter
  alias QuantumBilling.Repo
  alias QuantumBilling.Webhooks

  @secret "whsec_for_tests"

  setup do
    previous = System.get_env("RAZORPAY_WEBHOOK_SECRET")
    System.put_env("RAZORPAY_WEBHOOK_SECRET", @secret)
    RateLimiter.clear_all()

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("RAZORPAY_WEBHOOK_SECRET")
        value -> System.put_env("RAZORPAY_WEBHOOK_SECRET", value)
      end

      RateLimiter.clear_all()
    end)

    :ok
  end

  defp invoice_fixture(number) do
    Repo.insert!(%Invoice{
      invoice_number: number,
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_name: "Acme Corp",
      grand_total: 11_800,
      status: "Draft"
    })
  end

  defp payload(number) do
    %{
      "event" => "payment_link.paid",
      "payload" => %{
        "payment_link" => %{
          "entity" => %{
            "reference_id" => number,
            "id" => "plink_1",
            "amount_paid" => 1_180_000,
            "currency" => "INR"
          }
        },
        "payment" => %{"entity" => %{"id" => "pay_123"}}
      }
    }
  end

  defp post_signed(conn, body, opts \\ []) do
    signature =
      Keyword.get_lazy(opts, :signature, fn ->
        :hmac |> :crypto.mac(:sha256, @secret, body) |> Base.encode16(case: :lower)
      end)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-razorpay-signature", signature)
    |> then(fn conn ->
      case opts[:event_id] do
        nil -> conn
        id -> put_req_header(conn, "x-razorpay-event-id", id)
      end
    end)
    |> post(~p"/api/webhooks/razorpay", body)
  end

  test "a signed delivery reconciles the invoice", %{conn: conn} do
    invoice = invoice_fixture("INV-7001")
    body = Jason.encode!(payload(invoice.invoice_number))

    conn = post_signed(conn, body, event_id: "evt_7001")

    assert json_response(conn, 200)["status"] == "success"
    assert Repo.get(Invoice, invoice.id).status == "Paid"
    assert Repo.get(Invoice, invoice.id).razorpay_payment_id == "pay_123"
  end

  test "an unsigned delivery is refused and changes nothing", %{conn: conn} do
    invoice = invoice_fixture("INV-7002")
    body = Jason.encode!(payload(invoice.invoice_number))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/razorpay", body)

    assert json_response(conn, 401)["message"] =~ "signature"
    assert Repo.get(Invoice, invoice.id).status == "Draft"
  end

  test "a delivery signed with the wrong secret is refused", %{conn: conn} do
    invoice = invoice_fixture("INV-7003")
    body = Jason.encode!(payload(invoice.invoice_number))
    wrong = :hmac |> :crypto.mac(:sha256, "not-the-secret", body) |> Base.encode16(case: :lower)

    conn = post_signed(conn, body, signature: wrong)

    assert json_response(conn, 401)
    assert Repo.get(Invoice, invoice.id).status == "Draft"
  end

  test "with no secret configured the endpoint refuses everything", %{conn: conn} do
    System.delete_env("RAZORPAY_WEBHOOK_SECRET")

    invoice = invoice_fixture("INV-7004")
    body = Jason.encode!(payload(invoice.invoice_number))

    conn = post_signed(conn, body)

    # Without a secret, unverified deliveries are refused.
    assert json_response(conn, 503)
    assert Repo.get(Invoice, invoice.id).status == "Draft"
  end

  test "a redelivered event is acknowledged but not processed twice", %{conn: conn} do
    invoice = invoice_fixture("INV-7005")
    body = Jason.encode!(payload(invoice.invoice_number))

    assert conn |> post_signed(body, event_id: "evt_7005") |> json_response(200)

    # The provider retries. The invoice is already paid; the second delivery
    # must not run the side effects again.
    second = build_conn() |> post_signed(body, event_id: "evt_7005")

    assert json_response(second, 200)["message"] == "Already processed"
    assert Webhooks.get_event("razorpay", "evt_7005")
  end

  test "an event for an unknown invoice is reported, not silently accepted", %{conn: conn} do
    body = Jason.encode!(payload("INV-DOES-NOT-EXIST"))

    conn = post_signed(conn, body, event_id: "evt_missing")

    assert json_response(conn, 422)["reason"] =~ "invoice_not_found"
  end

  test "the signature is checked against the bytes that were sent", %{conn: conn} do
    # Signing a re-encoded copy of the params produces a different signature,
    # which is exactly the bug that the raw body reader exists to avoid.
    invoice = invoice_fixture("INV-7006")

    # Spaced and ordered the way a provider happens to send it. Re-encoding the
    # parsed params would produce different bytes and a different HMAC.
    body = """
    { "event" : "payment_link.paid" ,
      "payload" : { "payment_link" : { "entity" : { "reference_id" : "INV-7006" ,
                                                  "amount_paid" : 1180000 , "currency" : "INR" } } ,
                    "payment" : { "entity" : { "id" : "pay_7006" } } } }
    """

    signature = :hmac |> :crypto.mac(:sha256, @secret, body) |> Base.encode16(case: :lower)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-razorpay-signature", signature)
      |> post(~p"/api/webhooks/razorpay", body)

    assert json_response(conn, 200)["status"] == "success"
    assert Repo.get(Invoice, invoice.id).status == "Paid"
  end

  test "an under-payment is refused and the invoice stays unpaid", %{conn: conn} do
    invoice = invoice_fixture("INV-7010")

    body =
      invoice.invoice_number
      |> payload()
      |> put_in(["payload", "payment_link", "entity", "amount_paid"], 100)
      |> Jason.encode!()

    conn = post_signed(conn, body, event_id: "evt_7010")

    assert json_response(conn, 422)["reason"] == "amount_mismatch"
    assert Repo.get(Invoice, invoice.id).status == "Draft"
  end

  test "the ledger keeps no payer details, and stores the event encrypted", %{conn: conn} do
    invoice = invoice_fixture("INV-7011")

    body =
      invoice.invoice_number
      |> payload()
      |> put_in(["payload", "payment", "entity"], %{
        "id" => "pay_7011",
        "email" => "payer@example.com",
        "contact" => "+919999999999",
        "vpa" => "payer@okaxis",
        "card" => %{"last4" => "4242"}
      })
      |> Jason.encode!()

    conn = post_signed(conn, body, event_id: "evt_7011")
    assert json_response(conn, 200)["status"] == "success"

    {:duplicate, event} = Webhooks.claim("razorpay", "evt_7011")
    assert event.payload["payment"] == %{"id" => "pay_7011"}
    assert event.payload["payment_link"]["amount_paid"] == 1_180_000

    %{rows: [[raw]]} =
      Repo.query!("SELECT payload FROM webhook_events WHERE event_id = $1", ["evt_7011"])

    refute String.contains?(raw, "pay_7011")
    refute String.contains?(raw, "payer@example.com")
  end

  test "verify_webhook_signature/3 rejects anything but an exact match" do
    body = ~s({"a":1})
    signature = :hmac |> :crypto.mac(:sha256, @secret, body) |> Base.encode16(case: :lower)

    assert RazorpayClient.verify_webhook_signature(body, signature, @secret)
    refute RazorpayClient.verify_webhook_signature(body, String.upcase(signature), @secret)
    refute RazorpayClient.verify_webhook_signature(body, signature, "other")
    refute RazorpayClient.verify_webhook_signature(body, nil, @secret)
  end
end
