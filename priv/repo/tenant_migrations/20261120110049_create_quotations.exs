defmodule QuantumBilling.Repo.TenantMigrations.CreateQuotations do
  use Ecto.Migration

  @moduledoc """
  Quotations (estimates): a document with the same lines and tax as an invoice,
  its own number series, and no place in any tax figure. An accepted quotation
  converts into one invoice, linked by `invoices.quotation_id` (unique, so it
  converts only once).
  """

  @old_check "invoice_next_number > 0 AND credit_note_next_number > 0 AND " <>
               "debit_note_next_number > 0 AND " <>
               "(invoice_number_padding >= 0 AND invoice_number_padding <= 11)"

  @new_check "invoice_next_number > 0 AND credit_note_next_number > 0 AND " <>
               "debit_note_next_number > 0 AND quotation_next_number > 0 AND " <>
               "(invoice_number_padding >= 0 AND invoice_number_padding <= 11)"

  def up do
    create table(:quotations) do
      add :number, :string, null: false
      add :quotation_date, :date, null: false
      add :valid_until, :date, null: false
      add :status, :string, null: false, default: "Draft"
      add :place_of_supply, :string
      add :currency, :string, null: false, default: "INR"

      add :client_id, references(:clients, on_delete: :nilify_all)
      add :client_name, :string, null: false
      add :client_gstin, :string
      add :client_pan, :string
      add :client_billing_address, :text
      add :client_email, :string
      add :client_state, :string
      add :client_city, :string
      add :client_pincode, :string
      add :client_tax_number, :string

      add :company_name, :string
      add :company_address, :text
      add :company_gstin, :string
      add :company_state, :string
      add :company_tax_number, :string

      add :tax_regime, :string, null: false, default: "gst"
      add :reverse_charge, :boolean, null: false, default: false
      add :prices_include_tax, :boolean, null: false, default: false
      add :round_to_whole_units, :boolean, null: false, default: true

      add :total_items, :integer, null: false, default: 0
      add :total_quantity, :decimal, precision: 15, scale: 3, null: false, default: 0
      add :taxable_value, :bigint, null: false, default: 0
      add :cgst_amount, :bigint, null: false, default: 0
      add :sgst_amount, :bigint, null: false, default: 0
      add :igst_amount, :bigint, null: false, default: 0
      add :cess_amount, :bigint, null: false, default: 0
      add :vat_amount, :bigint, null: false, default: 0
      add :tax_breakdown, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :round_off, :bigint, null: false, default: 0
      add :grand_total, :bigint, null: false, default: 0

      add :remarks, :text
      add :terms, :text
      add :template_id, references(:invoice_templates, on_delete: :nilify_all)
      add :layout_xml, :text
      add :user_id, references(:users, prefix: "public", on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:quotations, [:number])
    create index(:quotations, [:status])
    create index(:quotations, [:valid_until])
    create index(:quotations, [:quotation_date])
    create index(:quotations, [:client_id])

    create constraint(:quotations, :quotations_valid_until_after_date,
             check: "valid_until >= quotation_date"
           )

    create table(:quotation_items) do
      add :quotation_id, references(:quotations, on_delete: :delete_all), null: false
      add :description, :string, null: false
      add :hsn_sac, :string
      add :quantity, :decimal, precision: 15, scale: 3, null: false, default: 1
      add :unit, :string, null: false, default: "Nos"
      add :rate, :bigint, null: false, default: 0
      add :tax_rate, :integer, null: false, default: 18
      add :tax_rate_id, references(:tax_rates, on_delete: :nilify_all)
      add :tax_rate_bp, :integer
      add :tax_category, :string
      add :tax_name, :string
      add :amount, :bigint, null: false, default: 0
      add :position, :integer, null: false, default: 0
      add :custom_fields, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:quotation_items, [:quotation_id])
    create index(:quotation_items, [:tax_rate_id])

    create constraint(:quotation_items, :quotation_items_amount_non_negative,
             check: "amount >= 0"
           )

    create constraint(:quotation_items, :quotation_items_quantity_positive,
             check: "quantity > 0"
           )

    create constraint(:quotation_items, :quotation_items_rate_non_negative, check: "rate >= 0")

    alter table(:invoices) do
      add :quotation_id, references(:quotations, on_delete: :nilify_all)
    end

    # Many invoices have no quotation (NULLs never clash); one quotation, one invoice.
    create unique_index(:invoices, [:quotation_id])

    alter table(:organization_settings) do
      add :quotation_prefix, :string, null: false, default: "QT"
      add :quotation_next_number, :integer, null: false, default: 1
    end

    drop constraint(:organization_settings, :organization_settings_numbering_valid)

    create constraint(:organization_settings, :organization_settings_numbering_valid,
             check: @new_check
           )
  end

  def down do
    drop constraint(:organization_settings, :organization_settings_numbering_valid)

    create constraint(:organization_settings, :organization_settings_numbering_valid,
             check: @old_check
           )

    alter table(:organization_settings) do
      remove :quotation_prefix
      remove :quotation_next_number
    end

    drop unique_index(:invoices, [:quotation_id])

    alter table(:invoices) do
      remove :quotation_id
    end

    drop table(:quotation_items)
    drop table(:quotations)
  end
end
