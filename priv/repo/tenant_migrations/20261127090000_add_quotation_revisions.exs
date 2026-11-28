defmodule QuantumBilling.Repo.TenantMigrations.AddQuotationRevisions do
  use Ecto.Migration

  def change do
    alter table(:quotations) do
      add :revision, :integer, null: false, default: 1
      add :sent_revision, :integer
    end
  end
end
