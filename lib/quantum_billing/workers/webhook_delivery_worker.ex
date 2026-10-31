defmodule QuantumBilling.Workers.WebhookDeliveryWorker do
  @moduledoc """
  Sends one recorded webhook delivery to its endpoint.

  The body was frozen when the event was published, so every attempt sends the
  same bytes under the same event id; only the signature's timestamp is fresh.
  The URL is checked and pinned at send time (`UrlGuard.pin/1`), and redirects
  are not followed.

  How an answer is taken:

    * 2xx — delivered.
    * 410 Gone — the receiver says the endpoint no longer exists: the delivery
      fails and the endpoint is switched off.
    * any other 4xx except 408 and 429 — the receiver refused this request;
      sending the same bytes again cannot change that, so it fails now.
    * 408, 429, 5xx, a timeout, a refused connection — retried, on the schedule
      below, for about a day.

  A delivery that ends in failure counts against its endpoint; enough in a row
  and `QuantumBilling.Webhooks` switches the endpoint off and tells the owners.
  Nothing from the response body is stored or logged: it is the receiver's,
  and could hold anything.
  """
  use QuantumBilling.Worker, queue: :webhooks, max_attempts: 9

  require Logger

  alias QuantumBilling.Repo
  alias QuantumBilling.Webhooks
  alias QuantumBilling.Webhooks.{Delivery, Endpoint, UrlGuard}

  @request_timeout_ms 10_000

  # Seconds before attempts 2..9: half a minute, then backing off to half a day.
  @backoff [30, 120, 600, 1_800, 3_600, 10_800, 21_600, 43_200]

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Enum.at(@backoff, attempt - 1, List.last(@backoff))

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: %{"delivery_id" => id}} = job) do
    case Repo.get(Delivery, id) do
      nil ->
        {:discard, "delivery #{id} no longer exists"}

      %Delivery{status: status} when status in ["succeeded", "cancelled"] ->
        :ok

      delivery ->
        endpoint = Repo.get(Endpoint, delivery.endpoint_id)
        attempt(delivery, endpoint, job)
    end
  end

  def process(%Oban.Job{}), do: {:discard, "no delivery named"}

  # A test may go to a disabled endpoint: it is how a fix is checked before the
  # endpoint is switched back on. Nothing else may.
  defp attempt(delivery, %Endpoint{enabled: false}, _job)
       when delivery.event_type != "webhook.test" do
    Webhooks.cancel(delivery, "The endpoint was switched off")
    :ok
  end

  defp attempt(delivery, %Endpoint{} = endpoint, job) do
    case UrlGuard.pin(endpoint.url) do
      {:ok, url, pin_options} ->
        delivery |> send_request(endpoint, url, pin_options) |> conclude(delivery, endpoint, job)

      {:error, reason} ->
        Logger.warning("[Webhooks] refusing #{delivery.event_type}: endpoint #{reason}")
        Webhooks.record_attempt(delivery, :failed, nil, "Refused: the URL #{reason}")
        :discard
    end
  end

  defp send_request(delivery, endpoint, url, pin_options) do
    timestamp = System.system_time(:second)

    headers =
      [
        {"content-type", "application/json"},
        {"user-agent", "QuantumBilling-Webhook/2"},
        {"x-quantumbilling-event", delivery.event_type},
        {"x-quantumbilling-event-id", delivery.event_id},
        {"x-quantumbilling-timestamp", to_string(timestamp)}
      ] ++ signature(endpoint, delivery.body, timestamp)

    Req.post(
      url,
      [
        body: delivery.body,
        headers: headers,
        receive_timeout: @request_timeout_ms,
        retry: false,
        # Not followed: a redirect target never went through UrlGuard.
        redirect: false,
        decode_body: false
      ] ++ pin_options
    )
  end

  # The legacy format keeps the signature its receiver was written against.
  defp signature(%Endpoint{format: "legacy", secret: secret}, _body, _timestamp)
       when secret in [nil, ""],
       do: []

  defp signature(%Endpoint{format: "legacy", secret: secret}, body, _timestamp),
    do: [{"x-quantumbilling-signature", Webhooks.sign(body, secret)}]

  defp signature(%Endpoint{} = endpoint, body, timestamp),
    do: [{"x-quantumbilling-signature", Webhooks.signature_header(endpoint, body, timestamp)}]

  defp conclude({:ok, %{status: status}}, delivery, _endpoint, _job) when status in 200..299 do
    Webhooks.record_attempt(delivery, :succeeded, status)
    :ok
  end

  defp conclude({:ok, %{status: 410}}, delivery, endpoint, _job) do
    Webhooks.record_attempt(delivery, :failed, 410, "The endpoint answered 410 Gone")
    Webhooks.disable_gone(endpoint)
    :discard
  end

  defp conclude({:ok, %{status: status}}, delivery, _endpoint, _job)
       when status in 400..499 and status not in [408, 429] do
    Webhooks.record_attempt(delivery, :failed, status, "Refused with HTTP #{status}")
    :discard
  end

  defp conclude({:ok, %{status: status}}, delivery, _endpoint, job) do
    retry_or_fail(delivery, job, status, "HTTP #{status}")
  end

  defp conclude({:error, exception}, delivery, _endpoint, job) do
    retry_or_fail(delivery, job, nil, transport_error(exception))
  end

  defp retry_or_fail(delivery, %Oban.Job{attempt: attempt, max_attempts: max}, status, error) do
    if attempt >= max do
      Webhooks.record_attempt(delivery, :failed, status, "Gave up: #{error}")
      :discard
    else
      Webhooks.record_attempt(delivery, :retrying, status, error)
      {:error, error}
    end
  end

  # Fixed words for the log shown to the owner: an exception message can carry
  # whatever the network stack put in it.
  defp transport_error(%{reason: :timeout}), do: "Timed out"
  defp transport_error(%{reason: :econnrefused}), do: "Connection refused"
  defp transport_error(%{reason: :nxdomain}), do: "Host not found"
  defp transport_error(_other), do: "Could not connect"
end
