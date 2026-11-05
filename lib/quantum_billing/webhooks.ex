defmodule QuantumBilling.Webhooks do
  @moduledoc """
  Webhooks in both directions.

  Incoming: `claim/3` inserts the event row, so each event is processed once.
  Outgoing: `publish/3` records a delivery per subscribed endpoint and queues
  a job. Events are thin (`{id, type, created_at, data: {object, id}}`) and
  signed as `x-quantumbilling-signature: t=<ts>,v1=<hex>` over `"<ts>.<body>"`.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Notifications
  alias QuantumBilling.Repo
  alias QuantumBilling.Webhooks.{Delivery, Endpoint, WebhookEvent}
  alias QuantumBilling.Workers.WebhookDeliveryWorker

  # Every event an endpoint can subscribe to, with the record it is about.
  @event_types %{
    "invoice.created" => "invoice",
    "invoice.updated" => "invoice",
    "invoice.paid" => "invoice",
    "invoice.cancelled" => "invoice",
    "invoice.e_invoice_generated" => "invoice",
    "invoice.e_invoice_failed" => "invoice",
    "client.created" => "client",
    "client.updated" => "client",
    "e_way_bill.generated" => "e_way_bill",
    "e_way_bill.cancelled" => "e_way_bill",
    "credit_note.created" => "credit_note"
  }

  # A rotated-out secret keeps signing alongside the new one for this long.
  @rotation_grace_seconds 24 * 60 * 60

  # Consecutive failed deliveries before an endpoint is switched off.
  @failure_limit 10

  @doc "Claims an incoming event: `{:ok, event}` to process it, or `{:duplicate, event}`."
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
      # A struct with no id means the row already existed.
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

  # Outgoing: events

  @doc "Every event type an endpoint can subscribe to, sorted."
  def event_types, do: @event_types |> Map.keys() |> Enum.sort()

  @doc """
  Announces `event_type` for record `id` to every subscribed, enabled endpoint.

  Returns `{:ok, event_id}` or `{:ok, nil}`. Never raises for delivery problems.
  """
  def publish(event_type, id, legacy_payload \\ nil) when is_map_key(@event_types, event_type) do
    endpoints = subscribed_endpoints(event_type)

    if endpoints == [] do
      {:ok, nil}
    else
      event_id = new_event_id()
      now = DateTime.utc_now(:second)
      object = Map.fetch!(@event_types, event_type)

      endpoints
      |> Enum.reduce(Multi.new(), fn endpoint, multi ->
        body = body(endpoint, event_id, event_type, object, id, now, legacy_payload)
        enqueue(multi, endpoint, event_id, event_type, body)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          {:ok, event_id}

        {:error, _step, reason, _changes} ->
          require Logger
          Logger.error("[Webhooks] could not queue #{event_type}: #{inspect(reason)}")
          {:ok, nil}
      end
    end
  end

  @doc "Sends a `webhook.test` event to `endpoint` alone, even while disabled."
  def send_test(%Endpoint{} = endpoint) do
    event_id = new_event_id()
    now = DateTime.utc_now(:second)

    body =
      Jason.encode!(%{
        id: event_id,
        type: "webhook.test",
        created_at: DateTime.to_iso8601(now),
        data: %{object: "endpoint", id: endpoint.id}
      })

    Multi.new()
    |> enqueue(endpoint, event_id, "webhook.test", body)
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, Map.fetch!(changes, {:delivery, endpoint.id})}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp subscribed_endpoints(event_type) do
    Repo.all(
      from e in Endpoint,
        where: e.enabled and ^event_type in e.events,
        order_by: [asc: e.id]
    )
  end

  defp enqueue(multi, endpoint, event_id, event_type, body) do
    multi
    |> Multi.insert({:delivery, endpoint.id}, %Delivery{
      endpoint_id: endpoint.id,
      event_id: event_id,
      event_type: event_type,
      body: body
    })
    |> Oban.insert({:job, endpoint.id}, fn changes ->
      WebhookDeliveryWorker.new(%{"delivery_id" => changes[{:delivery, endpoint.id}].id})
    end)
  end

  defp body(%Endpoint{format: "legacy"}, event_id, type, object, id, now, legacy_payload) do
    Jason.encode!(%{
      id: event_id,
      event: type,
      payload: legacy_payload || %{"#{object}_id" => id},
      sent_at: DateTime.to_iso8601(now)
    })
  end

  defp body(%Endpoint{}, event_id, type, object, id, now, _legacy_payload) do
    Jason.encode!(%{
      id: event_id,
      type: type,
      created_at: DateTime.to_iso8601(now),
      data: %{object: object, id: id}
    })
  end

  defp new_event_id,
    do: "evt_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  # Outgoing: endpoints

  @doc "Every endpoint of the current business, oldest first."
  def list_endpoints, do: Repo.all(from e in Endpoint, order_by: [asc: e.id])

  @doc "An endpoint by id, or `nil`."
  def get_endpoint(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get(Endpoint, id)
      _not_an_id -> nil
    end
  end

  @doc "A changeset for the endpoint form."
  def change_endpoint(%Endpoint{} = endpoint \\ %Endpoint{}, attrs \\ %{}),
    do: Endpoint.changeset(endpoint, attrs, event_types())

  @doc "Adds an endpoint and returns `{:ok, endpoint, secret}`. The secret is shown once."
  def create_endpoint(attrs, %User{} = owner) do
    secret = new_secret()

    %Endpoint{created_by_id: owner.id, secret: secret, format: "thin"}
    |> Endpoint.changeset(attrs, event_types())
    |> Repo.insert()
    |> case do
      {:ok, endpoint} ->
        audit(:webhook_endpoint_created, endpoint, owner)
        {:ok, endpoint, secret}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Switches an endpoint on or off. Switching on clears the failure state."
  def set_enabled(%Endpoint{} = endpoint, enabled?, %User{} = owner) when is_boolean(enabled?) do
    changes =
      if enabled?,
        do: [enabled: true, consecutive_failures: 0, disabled_reason: nil, disabled_at: nil],
        else: [enabled: false, disabled_reason: "Switched off by an owner", disabled_at: now()]

    with {:ok, endpoint} <- endpoint |> Ecto.Changeset.change(changes) |> Repo.update() do
      audit(
        if(enabled?, do: :webhook_endpoint_enabled, else: :webhook_endpoint_disabled),
        endpoint,
        owner
      )

      {:ok, endpoint}
    end
  end

  @doc """
  Issues a new secret and returns `{:ok, endpoint, secret}`.

  The old one keeps signing for a day. Legacy endpoints move to the thin format.
  """
  def rotate_secret(%Endpoint{} = endpoint, %User{} = owner) do
    secret = new_secret()

    endpoint
    |> Ecto.Changeset.change(
      secret: secret,
      previous_secret: endpoint.secret,
      previous_secret_expires_at:
        endpoint.secret && DateTime.add(now(), @rotation_grace_seconds, :second),
      format: "thin"
    )
    |> Repo.update()
    |> case do
      {:ok, endpoint} ->
        audit(:webhook_secret_rotated, endpoint, owner)
        {:ok, endpoint, secret}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Removes an endpoint and its delivery log. Queued deliveries are dropped."
  def delete_endpoint(%Endpoint{} = endpoint, %User{} = owner) do
    with {:ok, endpoint} <- Repo.delete(endpoint) do
      audit(:webhook_endpoint_deleted, endpoint, owner)
      {:ok, endpoint}
    end
  end

  defp new_secret,
    do: "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp audit(action, endpoint, owner) do
    QuantumBilling.Audit.log_event(action, "WebhookEndpoint", endpoint.id,
      user_id: owner.id,
      details: %{"url" => endpoint.url, "events" => endpoint.events}
    )

    # Where the business's activity is sent, and who can sign as us there.
    summary =
      case action do
        :webhook_endpoint_created -> "added a webhook endpoint sending to #{endpoint.url}"
        :webhook_endpoint_updated -> "changed the webhook endpoint to #{endpoint.url}"
        :webhook_secret_rotated -> "issued a new signing secret for #{endpoint.url}"
        _other -> nil
      end

    if summary, do: QuantumBilling.SecurityAlerts.admin_event(Repo.business(), owner, summary)
  end

  # Outgoing: deliveries

  @doc "The newest deliveries to `endpoint`, newest first."
  def list_deliveries(%Endpoint{id: endpoint_id}, limit \\ 50) do
    Repo.all(
      from d in Delivery,
        where: d.endpoint_id == ^endpoint_id,
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: ^limit
    )
  end

  @doc "A delivery of `endpoint` by id, or `nil`."
  def get_delivery(%Endpoint{id: endpoint_id}, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get_by(Delivery, id: id, endpoint_id: endpoint_id)
      _not_an_id -> nil
    end
  end

  @doc "Resends a delivery with the same event id and body."
  def resend(%Delivery{} = delivery) do
    Multi.new()
    |> Multi.update(:delivery, Ecto.Changeset.change(delivery, status: "pending"))
    |> Oban.insert(:job, WebhookDeliveryWorker.new(%{"delivery_id" => delivery.id}))
    |> Repo.transaction()
    |> case do
      {:ok, %{delivery: delivery}} -> {:ok, delivery}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "The signature header for `body`, with a second `v1` during a rotation grace period."
  def signature_header(%Endpoint{} = endpoint, body, timestamp) when is_integer(timestamp) do
    signed = "#{timestamp}.#{body}"

    endpoint
    |> signing_secrets()
    |> Enum.map(&("v1=" <> hmac(&1, signed)))
    |> then(&Enum.join(["t=#{timestamp}" | &1], ","))
  end

  @doc "Whether `header` validly signs `body` within `tolerance_seconds`. The receiver's check."
  def verify_signature(
        header,
        body,
        secret,
        now \\ System.system_time(:second),
        tolerance_seconds \\ 300
      ) do
    parts = header |> String.split(",") |> Enum.map(&String.split(&1, "=", parts: 2))

    with [["t", t] | signatures] <- parts,
         {timestamp, ""} <- Integer.parse(t),
         true <- abs(now - timestamp) <= tolerance_seconds do
      expected = hmac(secret, "#{timestamp}.#{body}")

      Enum.any?(signatures, fn
        ["v1", candidate] -> Plug.Crypto.secure_compare(candidate, expected)
        _other -> false
      end)
    else
      _malformed_or_stale -> false
    end
  end

  defp signing_secrets(%Endpoint{secret: secret} = endpoint) do
    previous =
      if endpoint.previous_secret && endpoint.previous_secret_expires_at &&
           DateTime.compare(endpoint.previous_secret_expires_at, now()) == :gt,
         do: [endpoint.previous_secret],
         else: []

    Enum.reject([secret | previous], &is_nil/1)
  end

  defp hmac(secret, data),
    do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)

  @doc false
  # How an attempt ended, as decided by the delivery worker.
  def record_attempt(%Delivery{} = delivery, outcome, status_code \\ nil, error \\ nil) do
    endpoint = Repo.get!(Endpoint, delivery.endpoint_id)
    at = now()

    delivery_changes =
      [
        attempts: delivery.attempts + 1,
        last_attempt_at: at,
        last_status_code: status_code,
        last_error: error
      ]
      |> Keyword.merge(
        case outcome do
          :succeeded -> [status: "succeeded", delivered_at: at, last_error: nil]
          :retrying -> [status: "pending"]
          :failed -> [status: "failed"]
        end
      )

    {:ok, delivery} = delivery |> Ecto.Changeset.change(delivery_changes) |> Repo.update()

    case outcome do
      :succeeded -> reset_failures(endpoint)
      :retrying -> :ok
      :failed -> count_failure(endpoint)
    end

    delivery
  end

  @doc false
  # 410 Gone: stop sending at once.
  def disable_gone(%Endpoint{} = endpoint) do
    disable(endpoint, "The endpoint answered 410 Gone")
  end

  @doc false
  def cancel(%Delivery{} = delivery, reason) do
    delivery |> Ecto.Changeset.change(status: "cancelled", last_error: reason) |> Repo.update!()
  end

  defp reset_failures(%Endpoint{consecutive_failures: 0}), do: :ok

  defp reset_failures(%Endpoint{id: id}) do
    Repo.update_all(from(e in Endpoint, where: e.id == ^id), set: [consecutive_failures: 0])
    :ok
  end

  defp count_failure(%Endpoint{id: id}) do
    {1, [failures]} =
      Repo.update_all(
        from(e in Endpoint, where: e.id == ^id, select: e.consecutive_failures),
        inc: [consecutive_failures: 1]
      )

    if failures >= @failure_limit do
      disable(Repo.get!(Endpoint, id), "#{@failure_limit} deliveries in a row failed")
    end

    :ok
  end

  defp disable(%Endpoint{enabled: false}, _reason), do: :ok

  defp disable(%Endpoint{} = endpoint, reason) do
    endpoint
    |> Ecto.Changeset.change(enabled: false, disabled_reason: reason, disabled_at: now())
    |> Repo.update!()

    Notifications.notify(%{
      kind: "system",
      severity: "warning",
      title: "Webhook endpoint switched off",
      body: "#{endpoint.url}: #{reason}. Fix it, send a test, then switch it back on.",
      path: "/settings/webhooks",
      dedupe_key: "webhook_disabled:#{endpoint.id}:#{DateTime.to_unix(now())}"
    })

    :ok
  end

  defp now, do: DateTime.utc_now(:second)

  @doc "HMAC-SHA256 over the exact bytes sent, keyed with the shared secret."
  def sign(body, secret) when is_binary(body) and is_binary(secret) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  @doc "Whether `signature` signs `body` under `secret`, compared in constant time."
  def valid_signature?(body, signature, secret)
      when is_binary(body) and is_binary(signature) and is_binary(secret) do
    Plug.Crypto.secure_compare(sign(body, secret), signature)
  end

  def valid_signature?(_body, _signature, _secret), do: false
end
