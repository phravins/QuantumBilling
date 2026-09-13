defmodule QuantumBilling.Webhooks do
  @moduledoc """
  Webhooks in both directions.

  ## Incoming

  `claim/3` is how a handler takes ownership of an event exactly once. It
  inserts the event row and reports whether this caller is the one that got it
  in: a redelivery — or two workers racing on the same event — loses the insert
  and is told the event is a duplicate, so the side effects behind it (marking
  an invoice paid, emailing a receipt) happen once no matter how many times the
  provider sends it.

  The uniqueness lives in the database rather than in a check-then-insert,
  because check-then-insert is not a claim: two processes can both find nothing
  and both proceed.

  ## Outgoing

  `dispatch/2` queues an event for the organisation's own webhook endpoint —
  the URL and signing secret in Settings, which until now were stored and never
  used. Delivery is a job, so a customer's endpoint being down slows nothing
  down here and is retried rather than lost.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Webhooks.WebhookEvent
  alias QuantumBilling.Workers.WebhookDispatchWorker

  @doc """
  Claims an incoming event.

  Returns `{:ok, event}` for the caller that should process it, or
  `{:duplicate, event}` when it has already been recorded.
  """
  def claim(provider, event_id, attrs \\ %{}) do
    changeset =
      WebhookEvent.changeset(%WebhookEvent{}, %{
        provider: to_string(provider),
        event_id: to_string(event_id),
        event_type: attrs[:event_type],
        payload: attrs[:payload] || %{},
        status: attrs[:status] || "processed"
      })

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:provider, :event_id]) do
      # `on_conflict: :nothing` returns a struct with no id when the row was
      # already there — that is the duplicate, and the existing row is what the
      # caller wants to see.
      {:ok, %WebhookEvent{id: nil}} ->
        {:duplicate, get_event(provider, event_id)}

      {:ok, event} ->
        {:ok, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Records how an already-claimed event turned out."
  def finish(%WebhookEvent{} = event, status, error \\ nil) do
    event
    |> WebhookEvent.changeset(%{status: to_string(status), error: error && to_string(error)})
    |> Repo.update()
  end

  @doc "One recorded event, or `nil`."
  def get_event(provider, event_id) do
    Repo.get_by(WebhookEvent, provider: to_string(provider), event_id: to_string(event_id))
  end

  @doc "The most recently received events, newest first."
  def list_recent_events(limit \\ 20) do
    Repo.all(from e in WebhookEvent, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit)
  end

  @doc """
  Queues `payload` for delivery to the organisation's webhook endpoint.

  Returns `{:ok, :not_configured}` when no endpoint is set, which is the
  ordinary case and not a failure — every caller would otherwise have to check
  the setting before announcing anything.
  """
  def dispatch(event_type, payload) when is_binary(event_type) and is_map(payload) do
    organization = Settings.get_organization()

    case organization.webhook_url do
      url when is_binary(url) and url != "" ->
        %{"event" => event_type, "payload" => payload}
        |> WebhookDispatchWorker.new()
        |> Oban.insert()

      _not_configured ->
        {:ok, :not_configured}
    end
  end

  @doc """
  The signature an endpoint uses to tell a real delivery from a forged one.

  HMAC-SHA256 over the exact bytes that are sent, keyed with the shared secret.
  The receiver recomputes it over the raw body: anything that re-encodes the
  JSON first is comparing a signature to a different document.
  """
  def sign(body, secret) when is_binary(body) and is_binary(secret) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  @doc """
  Whether `signature` is the signature of `body` under `secret`.

  Compared in constant time: a byte-by-byte comparison that returns early
  leaks, through timing, how much of a guessed signature was correct, which is
  enough to construct one.
  """
  def valid_signature?(body, signature, secret)
      when is_binary(body) and is_binary(signature) and is_binary(secret) do
    Plug.Crypto.secure_compare(sign(body, secret), signature)
  end

  def valid_signature?(_body, _signature, _secret), do: false
end
