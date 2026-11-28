defmodule QuantumBilling.Repo.Migrations.AddExportCountryToInvoices do
  use Ecto.Migration

  def change do
    alter table(:invoices) do
      add :client_country, :string
    end
  end
end
