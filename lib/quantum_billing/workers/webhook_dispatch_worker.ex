defmodule QuantumBilling.Workers.WebhookDispatchWorker do
  @moduledoc """
  Delivers an event to the organisation's own webhook endpoint.

  The endpoint and signing secret have been collectable in Settings >
  Integrations for a while without anything ever posting to them. This is what
  posts to them: an invoice being issued, paid or registered with the IRP is
  announced to whatever the business has pointed at that URL — an accounting
  system, an internal dashboard, a Zapier hook.

  ## Signed

  Every request carries `x-quantumbilling-signature`, an HMAC-SHA256 of the
  exact body under the shared secret, and `x-quantumbilling-timestamp`. Without
  a signature the endpoint has no way to tell the application's delivery from
  anybody else who learns the URL, and webhook URLs leak: they sit in logs,
  proxies and browser history.

  ## Retried, then dropped

  Six attempts with exponential backoff. A customer endpoint being down is
  normal and temporary; being down for a day means the event is stale anyway,
  and retrying for ever is how a queue fills up with a single broken
  integration.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 6

  require Logger

  alias QuantumBilling.Settings
  alias QuantumBilling.Webhooks

  @request_timeout_ms 10_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event} = args}) do
    organization = Settings.get_organization()
    url = organization.webhook_url

    if is_nil(url) or url == "" do
      # The endpoint was removed between queueing and running. Nothing to
      # deliver to, and no amount of retrying will conjure one.
      :discard
    else
      body = Jason.encode!(%{event: event, payload: args["payload"] || %{}, sent_at: now()})
      post(url, body, organization.webhook_secret, event)
    end
  end

  def perform(%Oban.Job{}), do: :discard

  defp post(url, body, secret, event) do
    headers =
      [
        {"content-type", "application/json"},
        {"user-agent", "QuantumBilling-Webhook/1"},
        {"x-quantumbilling-event", event},
        {"x-quantumbilling-timestamp", now()}
      ] ++ signature_header(body, secret)

    case Req.post(url,
           body: body,
           headers: headers,
           receive_timeout: @request_timeout_ms,
           retry: false,
           decode_body: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      # The endpoint is telling us the request itself is wrong — a bad URL, a
      # rejected signature, a payload it will never accept. Repeating it
      # unchanged cannot help.
      {:ok, %{status: status}} when status in 400..499 and status not in [408, 429] ->
        Logger.warning("[WebhookDispatchWorker] #{event} rejected with HTTP #{status}")
        :discard

      {:ok, %{status: status}} ->
        {:error, "webhook endpoint returned HTTP #{status}"}

      {:error, exception} ->
        {:error, "webhook delivery failed: #{Exception.message(exception)}"}
    end
  end

  defp signature_header(_body, secret) when secret in [nil, ""], do: []

  defp signature_header(body, secret),
    do: [{"x-quantumbilling-signature", Webhooks.sign(body, secret)}]

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
