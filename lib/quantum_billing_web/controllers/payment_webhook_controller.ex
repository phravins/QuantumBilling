defmodule QuantumBillingWeb.PaymentWebhookController do
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Payments
  alias QuantumBilling.Payments.RazorpayClient

  @doc """
  Handles POST requests from Razorpay webhook events.
  """
  def handle_razorpay(conn, params) do
    secret = System.get_env("RAZORPAY_WEBHOOK_SECRET", "")
    [signature] = get_req_header(conn, "x-razorpay-signature") ++ [""]
    raw_body = conn.private[:raw_body] || Jason.encode!(params)

    if secret == "" or RazorpayClient.verify_webhook_signature(raw_body, signature, secret) do
      case Payments.process_razorpay_webhook(params) do
        {:ok, _result} ->
          conn
          |> put_status(:ok)
          |> json(%{status: "success", message: "Webhook processed successfully"})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{status: "error", reason: to_string(reason)})
      end
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{status: "error", message: "Invalid webhook signature"})
    end
  end
end
