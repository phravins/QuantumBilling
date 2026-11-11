defmodule QuantumBilling.Repo.TenantMigrations.AllowInvoicesWithoutPlaceOfSupply do
  use Ecto.Migration

  @moduledoc """
  VAT invoices have no Indian place of supply. GST invoices still require one:
  `Invoice.changeset/3` checks it.
  """

  def change do
    alter table(:invoices) do
      modify :place_of_supply, :string, null: true, from: {:string, null: false}
    end
  end
end
