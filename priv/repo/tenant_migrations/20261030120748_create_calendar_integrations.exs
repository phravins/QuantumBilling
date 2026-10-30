defmodule QuantumBilling.Repo.Migrations.CreateCalendarIntegrations do
  use Ecto.Migration

  def change do
    create table(:calendar_connections) do
      add :provider, :string, null: false
      # A Google refresh token or a CalDAV password, encrypted by the schema.
      add :secret, :binary
      add :url, :text
      add :username, :string
      add :calendar_id, :string, null: false, default: "primary"
      add :feed_token_hash, :binary
      add :last_synced_at, :utc_datetime
      add :last_error, :string
      add :connected_by_id, references(:users, prefix: "public", on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:calendar_connections, [:provider])

    create table(:calendar_event_links) do
      add :connection_id, references(:calendar_connections, on_delete: :delete_all), null: false
      add :item_key, :string, null: false
      add :external_id, :text, null: false
      add :etag, :text
      add :fingerprint, :string, null: false
      add :due_date, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:calendar_event_links, [:connection_id, :item_key])
  end
end
