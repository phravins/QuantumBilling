defmodule QuantumBilling.ApiKeys do
  @moduledoc """
  External API keys and the idempotency records that make writes safe to retry.

  Only owners issue keys, and every issue and revocation is audited. Every
  function is scoped to one business and sees only that business's keys.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.ApiKeys.{ApiKey, IdempotencyKey}
  alias QuantumBilling.Audit
  alias QuantumBilling.Businesses.Business
  alias QuantumBilling.Repo

  # `last_used_at` is updated at most once a minute, so reads don't all become writes.
  @touch_interval_seconds 60

  # How long a write's response is kept for replay.
  @idempotency_ttl_seconds 24 * 60 * 60

  @doc "Every key of `business`, newest first."
  def list_keys(%Business{id: business_id}) do
    Repo.all(
      from k in ApiKey,
        where: k.business_id == ^business_id,
        order_by: [desc: k.inserted_at, desc: k.id],
        preload: [:created_by]
    )
  end

  @doc "A key of `business` by id, or `nil` — also when the id is another business's key."
  def get_key(%Business{id: business_id}, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get_by(ApiKey, id: id, business_id: business_id)
      _not_an_id -> nil
    end
  end

  @doc "A changeset for the new-key form."
  def change_key(attrs \\ %{}) do
    %ApiKey{}
    |> Ecto.Changeset.cast(attrs, [:name, :scopes, :expires_at])
  end

  @doc """
  Issues a key: `{:ok, %{key: key, raw: raw}}`. `raw` is shown once and never stored or logged.
  """
  def create_key(attrs, %User{} = owner, %Business{} = business) do
    {raw, changeset} = ApiKey.build(attrs, owner, business)

    with {:ok, key} <- Repo.insert(changeset) do
      QuantumBilling.SecurityAlerts.admin_event(
        business,
        owner,
        "created the API key \"#{key.name}\" (#{Enum.join(key.scopes, ", ")})"
      )

      Audit.log_event(:api_key_created, "ApiKey", key.id,
        user_id: owner.id,
        details: %{name: key.name, prefix: key.prefix, scopes: key.scopes}
      )

      {:ok, %{key: key, raw: raw}}
    end
  end

  @doc "Revokes a key. Requests made with it are refused from then on."
  def revoke_key(%ApiKey{revoked_at: %DateTime{}} = key, _owner), do: {:ok, key}

  def revoke_key(%ApiKey{} = key, %User{} = owner) do
    with {:ok, key} <- key |> ApiKey.revoke_changeset() |> Repo.update() do
      Audit.log_event(:api_key_revoked, "ApiKey", key.id,
        user_id: owner.id,
        details: %{name: key.name, prefix: key.prefix}
      )

      {:ok, key}
    end
  end

  @doc """
  The usable key for a raw bearer token, or `:error` for any malformed, unknown, revoked or expired key.
  """
  # The key's business must still be active; archiving a business stops its keys.
  def authenticate(raw) do
    with true <- ApiKey.well_formed?(raw),
         %ApiKey{} = key <-
           Repo.one(
             from k in ApiKey,
               join: b in assoc(k, :business),
               where: k.hashed_key == ^ApiKey.hash(raw) and is_nil(b.archived_at),
               preload: [business: b]
           ),
         true <- ApiKey.usable?(key) do
      {:ok, key}
    else
      _unusable -> :error
    end
  end

  @doc "Records that a key was just used, at most once a minute."
  def touch(%ApiKey{} = key, ip) do
    now = DateTime.utc_now(:second)

    stale? =
      is_nil(key.last_used_at) or
        DateTime.diff(now, key.last_used_at) >= @touch_interval_seconds

    if stale? do
      from(k in ApiKey, where: k.id == ^key.id)
      |> Repo.update_all(set: [last_used_at: now, last_used_ip: ip])
    end

    :ok
  end

  @doc """
  Claims an idempotency key for a write.

    * `{:proceed, record}` - first use: do the work, then `complete_idempotent/3`
      (or `abandon_idempotent/1` on a retryable failure).
    * `{:replay, status, body}` - already handled: return the stored response.
    * `{:error, :in_progress}` - the first request hasn't finished.
    * `{:error, :mismatch}` - the key was used for a different request.

  A unique index makes exactly one of two simultaneous retries proceed.
  """
  def begin_idempotent(%ApiKey{} = api_key, key, request_hash)
      when is_binary(key) and is_binary(request_hash) do
    expire_idempotent(api_key, key)

    record = %IdempotencyKey{api_key_id: api_key.id, key: key, request_hash: request_hash}

    case Repo.insert(record, on_conflict: :nothing, conflict_target: [:api_key_id, :key]) do
      {:ok, %IdempotencyKey{id: id} = inserted} when not is_nil(id) ->
        {:proceed, inserted}

      {:ok, _conflict} ->
        existing = Repo.get_by!(IdempotencyKey, api_key_id: api_key.id, key: key)

        cond do
          existing.request_hash != request_hash -> {:error, :mismatch}
          is_nil(existing.status) -> {:error, :in_progress}
          true -> {:replay, existing.status, existing.response_body}
        end
    end
  end

  @doc "Stores the response to a write, for replay."
  def complete_idempotent(%IdempotencyKey{} = record, status, body)
      when is_integer(status) and is_binary(body) do
    from(i in IdempotencyKey, where: i.id == ^record.id)
    |> Repo.update_all(set: [status: status, response_body: body])

    :ok
  end

  @doc """
  Releases a claim so the key can be retried. For crashes and timeouts, not validation errors.
  """
  def abandon_idempotent(%IdempotencyKey{} = record) do
    Repo.delete_all(from i in IdempotencyKey, where: i.id == ^record.id)
    :ok
  end

  # An expired record counts as absent, so a reused key starts afresh.
  defp expire_idempotent(api_key, key) do
    cutoff = DateTime.add(DateTime.utc_now(), -@idempotency_ttl_seconds, :second)

    Repo.delete_all(
      from i in IdempotencyKey,
        where: i.api_key_id == ^api_key.id and i.key == ^key and i.inserted_at < ^cutoff
    )
  end

  @doc "Deletes `business`'s expired idempotency records. Run daily."
  def prune_idempotency_keys(%Business{id: business_id}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@idempotency_ttl_seconds, :second)
    keys = from k in ApiKey, where: k.business_id == ^business_id, select: k.id

    {count, _} =
      Repo.delete_all(
        from i in IdempotencyKey,
          where: i.inserted_at < ^cutoff and i.api_key_id in subquery(keys)
      )

    {:ok, count}
  end
end
