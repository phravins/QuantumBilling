defmodule QuantumBilling.Repo.Migrations.CreateUserSignIns do
  @moduledoc """
  Where each account has signed in from, so a sign-in from somewhere new can
  be pointed out to the account holder (`QuantumBilling.SecurityAlerts`).

  In `public`: signing in happens before a business is chosen, and an account
  spans businesses. Rows older than 180 days are deleted as new ones arrive.
  """
  use Ecto.Migration

  def change do
    create table(:user_sign_ins) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :ip_address, :string, null: false
      add :user_agent, :string
      add :method, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_sign_ins, [:user_id, :ip_address])
    create index(:user_sign_ins, [:inserted_at])
  end
end
