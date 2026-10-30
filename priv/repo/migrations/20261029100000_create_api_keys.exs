defmodule QuantumBilling.Repo.Migrations.CreateApiKeys do
  @moduledoc """
  Keys for the external API and idempotency records for its writes.

  ## In `public`, with the business named

  A request arrives with nothing but a key, so the key has to be found before
  anyone knows which business it is for — it cannot live in a business's own
  schema. Each key names its business instead, and authenticating it is what
  makes that business current for the request.

  The audit trail is per business, so the column that attributes an entry to a
  key is added by a tenant migration.

  ## Keys are hashed, never stored

  A key is 32 random bytes. Only its SHA-256 is kept, the same reasoning as
  `user_tokens`: whoever can read this table must not come away holding keys
  that work. A slow password hash would buy nothing — that defends a short,
  guessable secret against brute force, and 256 random bits are not guessable.
  The prefix is stored in clear purely so an owner can tell keys apart.

  ## Idempotency

  Creating an invoice consumes a number in a statutory series. A client that
  times out and retries must not create a second one, so a write carries an
  Idempotency-Key and the response to it is kept for a day. The unique index on
  (key, idempotency key) is what makes two simultaneous retries resolve to one
  invoice rather than two.
  """
  use Ecto.Migration

  def change do
    create table(:api_keys) do
      add :business_id, references(:businesses, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :prefix, :string, null: false
      add :hashed_key, :binary, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :last_used_at, :utc_datetime
      add :last_used_ip, :string
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_keys, [:hashed_key])
    create unique_index(:api_keys, [:prefix])
    create index(:api_keys, [:business_id])

    create table(:api_idempotency_keys) do
      add :api_key_id, references(:api_keys, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :request_hash, :binary, null: false
      # Null while the first request carrying this key is still being handled.
      add :status, :integer
      add :response_body, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_idempotency_keys, [:api_key_id, :key])
    create index(:api_idempotency_keys, [:inserted_at])
  end
end
