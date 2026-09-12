defmodule QuantumBilling.Repo.Migrations.AddPublicTokenToInvoices do
  use Ecto.Migration

  def change do
    alter table(:invoices) do
      add :public_token, :string
    end

    create unique_index(:invoices, [:public_token])
  end
end
