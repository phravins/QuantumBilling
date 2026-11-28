defmodule QuantumBilling.Repo.TenantMigrations.AddQuotationRevisions do
  use Ecto.Migration

  def up do
    alter table(:quotations) do
      add :revision, :integer, null: false, default: 1
      add :accepted_revision, :integer
      add :accepted_total, :bigint
      add :accepted_at, :utc_datetime
    end

    execute """
    UPDATE "#{prefix()}".quotations
    SET accepted_revision = revision,
        accepted_total = grand_total,
        accepted_at = updated_at
    WHERE status = 'Accepted'
    """
  end

  def down do
    alter table(:quotations) do
      remove :accepted_at
      remove :accepted_total
      remove :accepted_revision
      remove :revision
    end
  end
end
