defmodule QuantumBilling.Repo.TenantMigrations.CreateTaxRates do
  use Ecto.Migration

  @moduledoc "The VAT rates a business charges. `rate_bp` is basis points: 750 is 7.5%."

  def change do
    create table(:tax_rates) do
      add :name, :string, null: false
      add :category, :string, null: false, default: "standard"
      add :rate_bp, :integer, null: false, default: 0
      add :exemption_reason, :string
      add :is_default, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:tax_rates, [:position])
  end
end
