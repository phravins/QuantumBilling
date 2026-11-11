defmodule QuantumBilling.Repo.TenantMigrations.AddTaxIdentityToClients do
  use Ecto.Migration

  @moduledoc "A VAT business's client: its VAT number or TRN and its country (ISO-2)."

  def change do
    alter table(:clients) do
      add :tax_number, :string
      add :country, :string, null: false, default: "IN"
    end
  end
end
