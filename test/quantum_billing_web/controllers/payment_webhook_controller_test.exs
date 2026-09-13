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
        "payment_link" => %{"entity" => %{"reference_id" => number, "id" => "plink_1"}},
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

    # The old behaviour was to accept unverified deliveries when no secret was
    # set, which let anyone mark any invoice paid.
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
      "payload" : { "payment_link" : { "entity" : { "reference_id" : "INV-7006" } } ,
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

  test "verify_webhook_signature/3 rejects anything but an exact match" do
    body = ~s({"a":1})
    signature = :hmac |> :crypto.mac(:sha256, @secret, body) |> Base.encode16(case: :lower)

    assert RazorpayClient.verify_webhook_signature(body, signature, @secret)
    refute RazorpayClient.verify_webhook_signature(body, String.upcase(signature), @secret)
    refute RazorpayClient.verify_webhook_signature(body, signature, "other")
    refute RazorpayClient.verify_webhook_signature(body, nil, @secret)
  end
end
