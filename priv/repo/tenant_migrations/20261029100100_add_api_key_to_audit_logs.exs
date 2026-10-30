defmodule QuantumBilling.Repo.TenantMigrations.AddApiKeyToAuditLogs do
  use Ecto.Migration

  @moduledoc """
  Lets an audit entry name the API key that made the change, where a person
  would otherwise be named. Keys live in `public`; tenant migrations run after
  the public ones, so the table is there to reference.
  """

  def change do
    alter table(:audit_logs) do
      add :api_key_id, references(:api_keys, prefix: "public", on_delete: :nilify_all)
    end

    create index(:audit_logs, [:api_key_id])
  end
end
