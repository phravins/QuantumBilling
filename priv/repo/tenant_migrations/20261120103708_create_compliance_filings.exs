defmodule QuantumBilling.Repo.Migrations.CreateComplianceFilings do
  use Ecto.Migration

  # One row per GST return the business has filed. Obligations themselves are
  # generated from the statute, so a filing is keyed by the obligation's type
  # and its period (MMYYYY), not by a foreign key.
  def change do
    create table(:compliance_filings) do
      add :type, :string, null: false
      add :period_key, :string, null: false
      add :filed_on, :date, null: false
      add :arn, :string
      add :note, :text
      add :user_id, references(:users, prefix: "public", on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:compliance_filings, [:type, :period_key])
  end
end
