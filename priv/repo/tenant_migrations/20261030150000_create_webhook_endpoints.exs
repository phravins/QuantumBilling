defmodule QuantumBilling.Repo.TenantMigrations.CreateWebhookEndpoints do
  use Ecto.Migration

  @moduledoc """
  Outgoing webhooks, v2: any number of endpoints per business, each with its
  own secret and events, and a record of every delivery.

  The single URL and secret in `organization_settings` become this business's
  first endpoint, in the `legacy` format: the same body, the same signature
  header and the same two events its receiver has always had, so nothing that
  already works breaks. The secret's ciphertext is copied as it is — the
  encryption is bound to the column type, not the table.
  """

  def up do
    schema = prefix()

    create table(:webhook_endpoints) do
      add :url, :text, null: false
      add :description, :string
      add :events, {:array, :string}, null: false, default: []
      add :format, :string, null: false, default: "thin"
      add :secret, :binary
      add :previous_secret, :binary
      add :previous_secret_expires_at, :utc_datetime
      add :enabled, :boolean, null: false, default: true
      add :consecutive_failures, :integer, null: false, default: 0
      add :disabled_reason, :string
      add :disabled_at, :utc_datetime
      add :created_by_id, references(:users, prefix: "public", on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create constraint(:webhook_endpoints, :webhook_endpoints_format_valid,
             check: "format IN ('thin', 'legacy')"
           )

    create table(:webhook_deliveries) do
      add :endpoint_id, references(:webhook_endpoints, on_delete: :delete_all), null: false
      add :event_id, :string, null: false
      add :event_type, :string, null: false
      # The exact bytes sent, frozen at publish time so every retry is identical.
      add :body, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_status_code, :integer
      add :last_error, :string
      add :last_attempt_at, :utc_datetime
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:webhook_deliveries, [:endpoint_id, :event_id])
    create index(:webhook_deliveries, [:endpoint_id, :inserted_at])
    create index(:webhook_deliveries, [:inserted_at])

    flush()

    execute("""
    INSERT INTO "#{schema}"."webhook_endpoints"
      (url, description, events, format, secret, enabled, inserted_at, updated_at)
    SELECT webhook_url,
           'Moved from Settings › Integrations',
           ARRAY['invoice.created', 'invoice.paid'],
           'legacy',
           webhook_secret,
           true,
           now(), now()
    FROM "#{schema}"."organization_settings"
    WHERE webhook_url IS NOT NULL AND btrim(webhook_url) <> ''
    ORDER BY id
    LIMIT 1
    """)
  end

  def down do
    drop table(:webhook_deliveries)
    drop table(:webhook_endpoints)
  end
end
