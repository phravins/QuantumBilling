defmodule QuantumBilling.Repo.TenantMigrations.AddBankDetailsToOrganizationSettings do
  use Ecto.Migration

  @moduledoc """
  Bank details for the Payment details block on an invoice, edited under
  Settings › Invoice. All optional: a business that takes payment only by UPI
  leaves them blank and the block prints no bank lines.
  """

  def change do
    alter table(:organization_settings) do
      add :bank_account_name, :string
      add :bank_name, :string
      add :bank_account_number, :string
      add :bank_ifsc, :string
      add :bank_branch, :string
    end
  end
end
