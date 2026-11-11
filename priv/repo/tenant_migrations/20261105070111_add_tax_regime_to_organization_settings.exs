defmodule QuantumBilling.Repo.TenantMigrations.AddTaxRegimeToOrganizationSettings do
  use Ecto.Migration

  @moduledoc """
  Whether the business charges India GST or VAT. `round_to_whole_units` nil
  means the regime's default: whole units for GST, exact for VAT.
  """

  def change do
    alter table(:organization_settings) do
      add :tax_regime, :string, null: false, default: "gst"
      add :vat_number, :string
      add :vat_country, :string
      add :prices_include_tax, :boolean, null: false, default: false
      add :round_to_whole_units, :boolean
    end
  end
end
