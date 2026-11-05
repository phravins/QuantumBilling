defmodule QuantumBillingWeb.PaymentWebhookController do
  @moduledoc """
  Receives Razorpay payment webhooks. Public, and it marks invoices paid, so:

    * a valid `x-razorpay-signature` over the raw body is required; with no
      `RAZORPAY_WEBHOOK_SECRET` set, everything is refused
    * each event id is claimed first, so redeliveries are handled once
    * requests are rate limited by source
    * only what reconciliation needs is stored, encrypted

  `/api/webhooks/razorpay/:slug` names the business; the bare path is legacy
  (first business). Duplicates return 200 so the provider stops retrying.
  """
  use QuantumBillingWeb, :controller

  require Logger

  alias QuantumBilling.Businesses
  alias QuantumBilling.Payments
  alias QuantumBilling.Payments.RazorpayClient
  alias QuantumBilling.RateLimiter
  alias QuantumBilling.Repo
  alias QuantumBilling.Webhooks

  @rate_limit 120
  @rate_limit_window_seconds 60

  def handle_razorpay(conn, params) do
    {slug, params} = Map.pop(params, "slug")

    with :ok <- check_rate_limit(conn),
         %{} = business <- Businesses.from_link(slug),
         {:ok, raw_body} <- raw_body(conn),
         :ok <- verify_signature(conn, raw_body) do
      # The endpoint clears this again before the next request on the connection.
      Repo.put_business(business)
      process(conn, params)
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{status: "error", message: "Unknown business"})

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{status: "error", message: "Too many requests"})

      {:error, :not_configured} ->
        Logger.error(
          "[PaymentWebhook] rejected: RAZORPAY_WEBHOOK_SECRET is not set, so no delivery " <>
            "can be verified. Set it to the secret configured in the Razorpay dashboard."
        )

        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", message: "Webhook verification is not configured"})

      {:error, reason} when reason in [:invalid_signature, :no_body] ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", message: "Invalid webhook signature"})
    end
  end

  defp process(conn, params) do
    event_id = event_id(conn, params)

    # Trimmed of payer details, and encrypted at rest by the ledger itself.
    case Webhooks.claim("razorpay", event_id, %{
           event_type: params["event"],
           payload: Payments.webhook_record(params)
         }) do
      {:duplicate, _event} ->
        # Acknowledged, or the provider retries for ever.
        conn |> put_status(:ok) |> json(%{status: "ok", message: "Already processed"})

      {:ok, event} ->
        case Payments.process_razorpay_webhook(params) do
          {:ok, _result} ->
            conn |> put_status(:ok) |> json(%{status: "success"})

          {:error, reason} ->
            _ = Webhooks.finish(event, "failed", inspect(reason))

            Logger.warning("[PaymentWebhook] #{params["event"]} failed: #{inspect(reason)}")

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", reason: to_string(reason)})
        end

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", reason: "event could not be recorded"})
    end
  end

  # The provider's event id, or a digest of the body.
  defp event_id(conn, params) do
    case get_req_header(conn, "x-razorpay-event-id") do
      [id | _] when byte_size(id) > 0 ->
        id

      _absent ->
        params
        |> Jason.encode!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    end
  end

  defp raw_body(conn) do
    case conn.private[:raw_body] do
      body when is_binary(body) and body != "" -> {:ok, body}
      _missing -> {:error, :no_body}
    end
  end

  defp verify_signature(conn, raw_body) do
    secret = System.get_env("RAZORPAY_WEBHOOK_SECRET")
    signature = List.first(get_req_header(conn, "x-razorpay-signature")) || ""

    cond do
      is_nil(secret) or secret == "" ->
        {:error, :not_configured}

      RazorpayClient.verify_webhook_signature(raw_body, signature, secret) ->
        :ok

      true ->
        Logger.warning("[PaymentWebhook] rejected a delivery with an invalid signature")
        {:error, :invalid_signature}
    end
  end

  defp check_rate_limit(conn) do
    key = {:razorpay_webhook, :inet.ntoa(conn.remote_ip) |> to_string()}

    case RateLimiter.hit(key, @rate_limit, @rate_limit_window_seconds) do
      {:ok, _remaining} -> :ok
      {:error, :rate_limited, retry_after} -> {:error, :rate_limited, retry_after}
    end
  end
end
