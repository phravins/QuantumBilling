defmodule QuantumBilling.Repo.TenantMigrations.TenantBaseline do
  use Ecto.Migration

  @moduledoc """
  The business tables, created in a new business's schema.

  Migrations in this directory run once for every business, with the business's
  schema as the prefix, so every table, index and constraint below lands in that
  schema. This first one is the tables as they stood when businesses moved into
  schemas of their own. Business 1 already had these tables and is recorded as
  having run it; a test checks that a new business comes out identical to it.

  Do not edit this migration to change business tables: existing businesses have
  already run it. Later changes go in new migrations here, written as usual;
  `prefix()` names the schema when one is needed in raw SQL.
  """

  def up do
    schema = prefix()

    unless is_binary(schema) and schema =~ ~r/\Abiz_\d+\z/ do
      raise "tenant migrations run with a business schema as prefix, got: #{inspect(schema)}"
    end

    create_clients()
    create_invoice_templates()
    create_invoices()
    create_invoice_items()
    create_credit_notes()
    create_e_way_bills()
    create_e_way_bill_part_b_updates()
    create_email_deliveries()
    create_recurring_profiles()
    create_notifications()
    create_audit_logs()
    create_webhook_events()
    create_organization_settings()
  end

  # Dropping a business's tables is dropping its books. That is never a rollback.
  def down do
    raise Ecto.MigrationError, "the tenant baseline cannot be rolled back"
  end

  defp create_clients do
    create table(:clients) do
      add :client_type, :string, null: false
      add :name, :string, null: false
      add :display_name, :string
      add :gstin, :string
      add :pan, :string
      add :legal_name, :string
      add :business_type, :string
      add :category, :string
      add :phone_country_code, :string, null: false, default: "+91"
      add :phone, :string
      add :email, :string
      add :billing_line1, :string
      add :billing_line2, :string
      add :billing_city, :string
      add :billing_state, :string
      add :billing_pin, :string
      add :shipping_same_as_billing, :boolean, null: false, default: true
      add :shipping_line1, :string
      add :shipping_line2, :string
      add :shipping_city, :string
      add :shipping_state, :string
      add :shipping_pin, :string
      add :credit_limit, :bigint, null: false, default: 0
      add :payment_terms_days, :integer, null: false, default: 30
      add :opening_balance, :bigint, null: false, default: 0
      add :notes, :text
      add :status, :string, null: false, default: "Active"
      add :outstanding, :bigint, null: false, default: 0
      timestamps()
      add :deleted_at, :naive_datetime
    end

    create index(:clients, [:deleted_at], where: "deleted_at IS NOT NULL")
    create index(:clients, [:email])
    create index(:clients, [:name])
    create index(:clients, [:status])

    create unique_index(:clients, [:gstin],
             name: :clients_gstin_unique,
             where: "gstin IS NOT NULL AND deleted_at IS NULL"
           )

    trigram_index(:clients, :email)
    trigram_index(:clients, :gstin)
    trigram_index(:clients, :name)
  end

  defp create_invoice_templates do
    create table(:invoice_templates) do
      add :name, :string, null: false
      add :layout_xml, :text, null: false
      add :accent, :string, null: false, default: "#18181b"
      add :is_default, :boolean, null: false, default: false
      add :archived_at, :naive_datetime
      timestamps()
    end

    create unique_index(:invoice_templates, [:name], where: "archived_at IS NULL")

    create unique_index(:invoice_templates, [:is_default],
             name: :invoice_templates_one_default_index,
             where: "is_default"
           )
  end

  defp create_invoices do
    create table(:invoices) do
      add :invoice_number, :string, null: false
      add :invoice_type, :string, null: false, default: "Tax Invoice"
      add :invoice_date, :date, null: false
      add :due_date, :date
      add :payment_terms, :string
      add :place_of_supply, :string, null: false
      add :client_id, references(:clients, on_delete: :nilify_all)
      add :client_name, :string, null: false
      add :client_gstin, :string
      add :client_pan, :string
      add :client_billing_address, :text
      add :client_email, :string
      add :client_state, :string
      add :company_name, :string
      add :company_address, :text
      add :company_gstin, :string
      add :company_state, :string
      add :remarks, :text
      add :terms, :text
      add :total_items, :integer, null: false, default: 0
      add :total_quantity, :decimal, precision: 15, scale: 3, null: false, default: 0
      add :taxable_value, :bigint, null: false, default: 0
      add :cgst_amount, :bigint, null: false, default: 0
      add :sgst_amount, :bigint, null: false, default: 0
      add :igst_amount, :bigint, null: false, default: 0
      add :cess_amount, :bigint, null: false, default: 0
      add :round_off, :bigint, null: false, default: 0
      add :grand_total, :bigint, null: false, default: 0
      add :status, :string, null: false, default: "Draft"
      timestamps()
      add :template_id, references(:invoice_templates, on_delete: :nilify_all)
      add :layout_xml, :text
      add :client_city, :string
      add :client_pincode, :string
      add :irn, :string
      add :ack_number, :string
      add :ack_date, :naive_datetime
      add :signed_qr_code, :text
      add :signed_invoice, :text
      add :currency, :string, default: "INR"
      add :exchange_rate, :decimal, default: 1.0
      add :export_type, :string, default: "DOMESTIC"
      add :lut_number, :string
      add :razorpay_payment_link_id, :string
      add :razorpay_payment_url, :string
      add :razorpay_payment_id, :string
      add :public_token, :string
      add :deleted_at, :naive_datetime
    end

    create constraint(:invoices, :invoices_totals_non_negative,
             check: """
             taxable_value >= 0 AND cgst_amount >= 0 AND sgst_amount >= 0 AND igst_amount >= 0 \
             AND cess_amount >= 0 AND grand_total >= 0 AND total_items >= 0 AND total_quantity >= 0\
             """
           )

    create unique_index(:invoices, [:invoice_number])
    create unique_index(:invoices, [:public_token])
    create unique_index(:invoices, [:irn], name: :invoices_irn_unique, where: "irn IS NOT NULL")

    create index(:invoices, [:client_gstin])
    create index(:invoices, [:client_id])
    create index(:invoices, [:client_name])
    create index(:invoices, [:deleted_at], where: "deleted_at IS NOT NULL")
    create index(:invoices, [:inserted_at])
    create index(:invoices, [:invoice_date])
    create index(:invoices, [:irn])
    create index(:invoices, [:razorpay_payment_id])
    create index(:invoices, [:razorpay_payment_link_id])
    create index(:invoices, [:status])
    create index(:invoices, [:status, :invoice_date])
    create index(:invoices, [:template_id])

    # Keyset pagination over the live (not binned) invoices.
    for column <- [:due_date, :grand_total, :status] do
      create index(:invoices, [column, :id],
               name: :"invoices_kept_#{column}_id_index",
               where: "deleted_at IS NULL"
             )
    end

    trigram_index(:invoices, :client_gstin)
    trigram_index(:invoices, :client_name)
    trigram_index(:invoices, :invoice_number)
  end

  defp create_invoice_items do
    create table(:invoice_items) do
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false
      add :description, :string, null: false
      add :hsn_sac, :string
      add :quantity, :decimal, precision: 15, scale: 3, null: false, default: 1
      add :unit, :string, null: false, default: "Nos"
      add :rate, :bigint, null: false, default: 0
      add :tax_rate, :integer, null: false, default: 18
      add :amount, :bigint, null: false, default: 0
      add :position, :integer, null: false, default: 0
      timestamps()
    end

    create constraint(:invoice_items, :invoice_items_amount_non_negative, check: "amount >= 0")
    create constraint(:invoice_items, :invoice_items_quantity_positive, check: "quantity > 0")
    create constraint(:invoice_items, :invoice_items_rate_non_negative, check: "rate >= 0")

    create index(:invoice_items, [:invoice_id])
  end

  defp create_credit_notes do
    create table(:credit_notes) do
      add :note_number, :string, null: false
      add :note_type, :string, null: false, default: "Credit"
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :restrict), null: false
      add :reason, :string
      add :subtotal, :bigint, default: 0
      add :tax_total, :bigint, default: 0
      add :grand_total, :bigint, default: 0
      add :status, :string, default: "Issued"
      timestamps()
    end

    create unique_index(:credit_notes, [:note_number])
    create index(:credit_notes, [:client_id])
    create index(:credit_notes, [:invoice_id])
  end

  defp create_e_way_bills do
    create table(:e_way_bills) do
      add :ewb_number, :string, null: false
      add :ewb_date, :date, null: false
      add :valid_until, :naive_datetime, null: false
      add :status, :string, null: false, default: "Active"
      add :distance_km, :integer, null: false
      add :mode_of_transport, :string, null: false, default: "Road"
      add :vehicle_number, :string
      add :transporter_id, :string
      add :transporter_name, :string
      add :cancelled_at, :naive_datetime
      add :cancellation_reason, :string
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false
      timestamps()
      add :deleted_at, :naive_datetime
    end

    create unique_index(:e_way_bills, [:ewb_number])

    create unique_index(:e_way_bills, [:invoice_id],
             name: :e_way_bills_one_live_bill_per_invoice_index,
             where: "status <> 'Cancelled' AND deleted_at IS NULL"
           )

    create index(:e_way_bills, [:deleted_at], where: "deleted_at IS NOT NULL")
    create index(:e_way_bills, [:ewb_date, :id])
    create index(:e_way_bills, [:invoice_id])
    create index(:e_way_bills, [:status])

    trigram_index(:e_way_bills, :ewb_number)
  end

  defp create_e_way_bill_part_b_updates do
    create table(:e_way_bill_part_b_updates) do
      add :vehicle_number, :string, null: false
      add :mode_of_transport, :string, null: false, default: "Road"
      add :place, :string
      add :reason, :string
      add :updated_on, :naive_datetime, null: false
      add :e_way_bill_id, references(:e_way_bills, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:e_way_bill_part_b_updates, [:e_way_bill_id])
  end

  defp create_email_deliveries do
    create table(:email_deliveries) do
      add :to_email, :string, null: false
      add :kind, :string, null: false, default: "invoice"
      add :subject, :string
      add :invoice_id, references(:invoices, on_delete: :nilify_all)
      add :status, :string, null: false, default: "queued"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :delivered_at, :naive_datetime
      timestamps()
    end

    create constraint(:email_deliveries, :email_deliveries_status_known,
             check: "status IN ('queued', 'sent', 'failed')"
           )

    create index(:email_deliveries, [:inserted_at])
    create index(:email_deliveries, [:invoice_id])
    create index(:email_deliveries, [:status])
  end

  defp create_recurring_profiles do
    create table(:recurring_profiles) do
      add :title, :string, null: false
      add :frequency, :string, null: false, default: "Monthly"
      add :next_run_date, :date, null: false
      add :status, :string, null: false, default: "Active"
      add :auto_send_email, :boolean, null: false, default: true
      add :client_id, references(:clients, on_delete: :nilify_all)
      add :items_json, :text
      timestamps()
      add :deleted_at, :naive_datetime
    end

    create index(:recurring_profiles, [:client_id])
    create index(:recurring_profiles, [:deleted_at], where: "deleted_at IS NOT NULL")
    create index(:recurring_profiles, [:next_run_date])
    create index(:recurring_profiles, [:status])
    create index(:recurring_profiles, [:status, :next_run_date])
  end

  defp create_notifications do
    create table(:notifications) do
      add :kind, :string, null: false
      add :title, :string, null: false
      add :body, :string
      add :path, :string
      add :severity, :string, null: false, default: "info"
      add :dedupe_key, :string
      add :read_at, :naive_datetime
      timestamps()
    end

    create unique_index(:notifications, [:dedupe_key], where: "dedupe_key IS NOT NULL")
    create index(:notifications, [:inserted_at, :id])
    create index(:notifications, [:read_at], where: "read_at IS NULL")
  end

  defp create_audit_logs do
    create table(:audit_logs) do
      # Accounts are shared by every business, so they stay in public.
      add :user_id, references(:users, prefix: "public", on_delete: :nilify_all)
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :string
      add :details, :map, default: %{}
      add :ip_address, :string
      timestamps(updated_at: false)
    end

    create index(:audit_logs, [:action])
    create index(:audit_logs, [:inserted_at])
    create index(:audit_logs, [:resource_type, :resource_id])
    create index(:audit_logs, [:user_id])
  end

  defp create_webhook_events do
    create table(:webhook_events) do
      add :provider, :string, null: false
      add :event_id, :string, null: false
      add :event_type, :string
      add :status, :string, null: false, default: "processed"
      add :error, :text
      timestamps()
      add :payload, :binary, null: false
    end

    create unique_index(:webhook_events, [:provider, :event_id])
    create index(:webhook_events, [:inserted_at])
  end

  # The sign-in rule columns (allowed_ips, session_timeout_minutes, enforce_2fa)
  # are dropped again by the next tenant migration; they stay here because
  # business 1 had them when it was recorded as having run this one.
  defp create_organization_settings do
    create table(:organization_settings) do
      add :company_name, :string
      add :trade_name, :string
      add :address, :text
      add :phone, :string
      add :email, :string
      add :gstin, :string
      add :pan, :string
      add :state, :string
      add :currency, :string, null: false, default: "INR"
      add :financial_year, :string
      add :timezone, :string, null: false, default: "Asia/Kolkata"
      add :date_format, :string, null: false, default: "DD MMM YYYY"
      add :invoice_prefix, :string, null: false, default: "INV"
      add :invoice_next_number, :integer, null: false, default: 1
      add :invoice_number_padding, :integer, null: false, default: 4
      add :invoice_due_days, :integer, null: false, default: 30
      add :invoice_terms, :text
      add :ewb_transport_mode, :string, null: false, default: "Road"
      add :ewb_transporter_id, :string
      add :ewb_threshold_value, :bigint, null: false, default: 5_000_000
      add :ewb_auto_generate, :boolean, null: false, default: false
      add :default_gst_rate, :integer, null: false, default: 18
      add :cess_enabled, :boolean, null: false, default: false
      add :composition_scheme, :boolean, null: false, default: false
      add :tds_enabled, :boolean, null: false, default: false
      add :notify_invoice_created, :boolean, null: false, default: true
      add :notify_ewb_generated, :boolean, null: false, default: true
      add :notify_filing_reminders, :boolean, null: false, default: true
      add :reminder_lead_days, :integer, null: false, default: 7
      add :language, :string, null: false, default: "en"
      add :rows_per_page, :integer, null: false, default: 10
      add :singleton, :boolean, null: false, default: true
      timestamps()
      add :doc_logo_path, :string
      add :city, :string
      add :pincode, :string
      add :smtp_host, :string
      add :smtp_port, :integer, default: 587
      add :smtp_username, :string
      add :smtp_ssl, :boolean, default: false
      add :smtp_from_email, :string
      add :smtp_from_name, :string
      add :razorpay_key_id, :string
      add :irp_username, :string
      add :irp_client_id, :string
      add :webhook_url, :string
      add :allowed_ips, :string
      add :session_timeout_minutes, :integer, default: 60
      add :enforce_2fa, :boolean, default: false
      add :audit_retention_days, :integer, default: 90
      add :smtp_password, :binary
      add :razorpay_key_secret, :binary
      add :irp_password, :binary
      add :webhook_secret, :binary
      add :upi_vpa, :string
      add :upi_payee_name, :string
    end

    create constraint(:organization_settings, :organization_settings_numbering_valid,
             check:
               "invoice_next_number > 0 AND (invoice_number_padding >= 0 AND invoice_number_padding <= 11)"
           )

    create constraint(:organization_settings, :organization_settings_security_valid,
             check: """
             (session_timeout_minutes IS NULL OR session_timeout_minutes > 0) \
             AND (audit_retention_days IS NULL OR audit_retention_days > 0)\
             """
           )

    # One settings row per business.
    create unique_index(:organization_settings, [:singleton],
             name: :organization_settings_singleton
           )
  end

  # Fuzzy search. The pg_trgm operator class lives in public with the extension.
  defp trigram_index(table, column) do
    create index(table, ["#{column} public.gin_trgm_ops"],
             name: :"#{table}_#{column}_trgm_index",
             using: :gin
           )
  end
end
