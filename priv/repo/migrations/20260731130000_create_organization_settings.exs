defmodule QuantumBilling.Repo.Migrations.CreateOrganizationSettings do
  use Ecto.Migration

  @moduledoc """
  The organisation's configuration: one row, one column per setting.

  Columns rather than a JSON blob, so every setting gets a database type and a
  changeset validation rather than being an untyped bag.

  This lives in `public` with a single row. The recorded architecture for this
  project is schema-per-tenant via Ecto's `prefix`, so when tenancy lands this
  table moves into the per-tenant schema and loses its singleton constraint.
  """

  def change do
    create table(:organization_settings) do
      # Identity
      add :company_name, :string
      add :trade_name, :string
      add :address, :text
      add :phone, :string
      add :email, :string

      # Tax registration
      add :gstin, :string
      add :pan, :string
      add :state, :string

      # Locale
      add :currency, :string, null: false, default: "INR"
      add :financial_year, :string
      add :timezone, :string, null: false, default: "Asia/Kolkata"
      add :date_format, :string, null: false, default: "DD MMM YYYY"

      # Invoice
      add :invoice_prefix, :string, null: false, default: "INV"
      add :invoice_next_number, :integer, null: false, default: 1
      add :invoice_number_padding, :integer, null: false, default: 4
      add :invoice_due_days, :integer, null: false, default: 30
      add :invoice_terms, :text

      # E-way bill
      add :ewb_transport_mode, :string, null: false, default: "Road"
      add :ewb_transporter_id, :string
      # Whole rupees, matching the convention used elsewhere. 50,000 is the
      # statutory threshold above which an e-way bill is required.
      add :ewb_threshold_value, :integer, null: false, default: 50_000
      add :ewb_auto_generate, :boolean, null: false, default: false

      # Tax
      add :default_gst_rate, :integer, null: false, default: 18
      add :cess_enabled, :boolean, null: false, default: false
      add :composition_scheme, :boolean, null: false, default: false
      add :tds_enabled, :boolean, null: false, default: false

      # Notifications
      add :notify_invoice_created, :boolean, null: false, default: true
      add :notify_ewb_generated, :boolean, null: false, default: true
      add :notify_filing_reminders, :boolean, null: false, default: true
      add :reminder_lead_days, :integer, null: false, default: 7

      # Preferences
      add :language, :string, null: false, default: "en"
      add :rows_per_page, :integer, null: false, default: 10

      # There is exactly one organisation until tenancy exists. This column is
      # always true, so a unique index on it permits a single row and makes a
      # second insert fail loudly instead of silently creating a rival copy of
      # the settings. A unique index on :id would not do this — the primary key
      # is already unique, so every row would satisfy it.
      add :singleton, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_settings, [:singleton],
             name: :organization_settings_singleton
           )
  end
end
