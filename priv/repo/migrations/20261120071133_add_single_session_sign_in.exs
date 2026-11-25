defmodule QuantumBilling.Repo.Migrations.AddSingleSessionSignIn do
  use Ecto.Migration

  # "One device at a time": the installation-wide switch, which device each
  # session token belongs to and when it was last used, and the sign-in
  # requests a signed-in device answers. All installation-wide, so public.
  def change do
    alter table(:installation_settings, prefix: "public") do
      add :single_session, :boolean, null: false, default: false
    end

    alter table(:users_tokens, prefix: "public") do
      add :device_id, :string
      add :user_agent, :string
      add :ip_address, :string
      add :last_seen_at, :utc_datetime
    end

    create index(:users_tokens, [:user_id, :context], prefix: "public")

    create table(:sign_in_requests, prefix: "public") do
      add :user_id, references(:users, on_delete: :delete_all, prefix: "public"), null: false
      # SHA-256 of the token held in the waiting browser's session.
      add :token, :binary, null: false
      add :device_id, :string
      add :user_agent, :string
      add :ip_address, :string
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sign_in_requests, [:token], prefix: "public")
    create index(:sign_in_requests, [:user_id, :status], prefix: "public")
  end
end
