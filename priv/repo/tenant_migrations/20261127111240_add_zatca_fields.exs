defmodule QuantumBilling.Repo.TenantMigrations.AddZatcaFields do
  use Ecto.Migration

  @moduledoc """
  Saudi Arabia, ZATCA Phase 1 (#94).

  The business gets an Arabic name and address. Each invoice snapshots them,
  and the VAT country it was issued under, so its QR code and Arabic copy
  never change when Settings do.

  Existing VAT invoices take the business's current VAT country, the only
  record there is of the one they were issued under, so Saudi invoices
  already issued get their QR code too. Their Arabic name and address stay
  empty: the QR code then carries the English name.
  """

  def change do
    alter table(:organization_settings) do
      add :company_name_ar, :string
      add :address_ar, :text
    end

    alter table(:invoices) do
      add :company_name_ar, :string
      add :company_address_ar, :text
      add :company_vat_country, :string
    end

    # Raw SQL skips Ecto's prefix, so the business schema is named. A rollback
    # drops the column, so there is nothing to undo.
    execute(
      """
      UPDATE "#{prefix()}"."invoices"
      SET company_vat_country = (
        SELECT vat_country FROM "#{prefix()}"."organization_settings" LIMIT 1
      )
      WHERE tax_regime = 'vat'
      """,
      fn -> :ok end
    )
  end
end
