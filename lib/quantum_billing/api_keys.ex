defmodule QuantumBilling.ApiKeys do
  @moduledoc """
  Keys for the external API, and the idempotency records that make its writes
  safe to retry.

  Keys are issued by a business's owner only — see
  `QuantumBillingWeb.SettingsLive.ApiKeys` — and every issue and revocation is
  audited. A key belongs to one business and is a credential onto all of that
  business's books within its scopes, so it is treated with that weight.

  Every function that lists or changes keys takes the business, and only ever
  sees that business's keys: an owner of one firm on a shared installation must
  not be able to read, or revoke, another firm's.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.ApiKeys.{ApiKey, IdempotencyKey}
  alias QuantumBilling.Audit
  alias QuantumBilling.Businesses.Business
  alias QuantumBilling.Repo

  # `last_used_at` is for an owner deciding whether a key is still in use, so a
  # minute's precision is plenty — and writing it on every request would turn
  # each API read into a database write.
  @touch_interval_seconds 60

  # How long a write's response is kept for replay. Long enough to cover any
  # sensible retry policy, short enough that the table stays small.
  @idempotency_ttl_seconds 24 * 60 * 60

  ## Keys

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
  Issues a key, returning `{:ok, %{key: key, raw: raw}}`.

  `raw` is the only time the full key exists outside the system it is given to.
  It is returned to be shown once and is never logged or stored.
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
  The usable key for a raw bearer token, or `:error`.

  `:error` is the single answer for a malformed, unknown, revoked or expired
  key. Telling those apart to the caller would tell an attacker which guesses
  were close.
  """
  #
  # The key comes back with its business, which must still be active: archiving
  # a business takes it off every picker and out of every sweep, and its keys
  # stop with it.
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

  ## Idempotency

  @doc """
  Claims an idempotency key for a write about to be performed.

    * `{:proceed, record}` — first sight of this key: do the work, then call
      `complete_idempotent/3` (or `abandon_idempotent/1` if it failed in a way
      worth retrying).
    * `{:replay, status, body}` — this exact request was already handled;
      return the stored response instead of doing it again.
    * `{:error, :in_progress}` — the first request with this key has not
      finished yet.
    * `{:error, :mismatch}` — the key was used for a *different* request.
      Replaying that response would answer a question nobody asked.

  The claim is an insert against a unique index, so of two simultaneous
  retries exactly one proceeds — which is the whole point when the write
  consumes a number in a statutory invoice series.
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
  Releases a claim, so the same key can be retried.

  For failures that were not the request's fault — a crash, a timeout. A
  validation error is the request's fault and is stored instead: sending it
  again will fail the same way, and should say so the same way.
  """
  def abandon_idempotent(%IdempotencyKey{} = record) do
    Repo.delete_all(from i in IdempotencyKey, where: i.id == ^record.id)
    :ok
  end

  # A record past its lifetime is treated as never having existed, so a key
  # reused after a day starts afresh rather than replaying yesterday.
  defp expire_idempotent(api_key, key) do
    cutoff = DateTime.add(DateTime.utc_now(), -@idempotency_ttl_seconds, :second)

    Repo.delete_all(
      from i in IdempotencyKey,
        where: i.api_key_id == ^api_key.id and i.key == ^key and i.inserted_at < ^cutoff
    )
  end

  @doc """
  Deletes `business`'s idempotency records past their lifetime. Run daily, by
  the per-business sweep.
  """
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
