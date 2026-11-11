defmodule QuantumBilling.Repo.TenantMigrations.CreateFieldDefinitions do
  use Ecto.Migration

  @moduledoc """
  The custom fields an owner has added to clients, invoices, invoice lines,
  credit notes, e-way bills and recurring profiles. Values live in each
  record's `custom_fields` column, keyed by `key`.
  """

  def change do
    create table(:field_definitions) do
      add :object, :string, null: false
      add :key, :string, null: false
      add :label, :string, null: false
      add :type, :string, null: false
      add :options, :map, null: false, default: %{}
      add :required, :boolean, null: false, default: false
      add :help_text, :string
      add :position, :integer, null: false, default: 0
      add :show_in_list, :boolean, null: false, default: false
      add :filterable, :boolean, null: false, default: false
      add :show_on_invoice, :boolean, null: false, default: false
      add :include_in_api, :boolean, null: false, default: true
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:field_definitions, [:object, :key])
    create index(:field_definitions, [:object, :position])
  end
end
