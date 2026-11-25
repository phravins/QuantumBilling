defmodule QuantumBilling.Repo.TenantMigrations.AddQuotationExtras do
  use Ecto.Migration

  @moduledoc """
  Quotations get a Bin (`deleted_at`), custom fields, a public link token,
  and the business chooses how long a new quotation stays valid.

  Existing quotations have no token yet; one is made the first time a link
  is asked for.
  """

  def up do
    alter table(:quotations) do
      add :deleted_at, :utc_datetime
      add :custom_fields, :map, null: false, default: %{}
      add :public_token, :string
    end

    create index(:quotations, [:deleted_at])
    create unique_index(:quotations, [:public_token])

    alter table(:organization_settings) do
      add :quotation_validity_days, :integer, null: false, default: 30
    end

    create constraint(:organization_settings, :organization_settings_quotation_validity_valid,
             check: "quotation_validity_days BETWEEN 1 AND 365"
           )
  end

  def down do
    drop constraint(:organization_settings, :organization_settings_quotation_validity_valid)

    alter table(:organization_settings) do
      remove :quotation_validity_days
    end

    drop unique_index(:quotations, [:public_token])
    drop index(:quotations, [:deleted_at])

    alter table(:quotations) do
      remove :deleted_at
      remove :custom_fields
      remove :public_token
    end
  end
end
