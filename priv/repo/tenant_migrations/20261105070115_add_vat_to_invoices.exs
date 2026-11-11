defmodule QuantumBilling.Repo.TenantMigrations.AddVatToInvoices do
  use Ecto.Migration

  @moduledoc """
  VAT on invoices, their lines and credit notes. Existing rows default to GST,
  so nothing is backfilled. A line snapshots its rate's name, category and
  basis points, so editing a rate never changes an issued invoice.
  """

  def change do
    alter table(:invoices) do
      add :tax_regime, :string, null: false, default: "gst"
      add :vat_amount, :bigint, null: false, default: 0
      add :tax_breakdown, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :company_tax_number, :string
      add :client_tax_number, :string
      add :reverse_charge, :boolean, null: false, default: false
      add :prices_include_tax, :boolean, null: false, default: false
      add :round_to_whole_units, :boolean, null: false, default: true
    end

    alter table(:invoice_items) do
      add :tax_rate_id, references(:tax_rates, on_delete: :nilify_all)
      add :tax_rate_bp, :integer
      add :tax_category, :string
      add :tax_name, :string
    end

    create index(:invoice_items, [:tax_rate_id])

    alter table(:credit_notes) do
      add :tax_regime, :string, null: false, default: "gst"
      add :tax_breakdown, :jsonb, null: false, default: fragment("'[]'::jsonb")
    end
  end
end
