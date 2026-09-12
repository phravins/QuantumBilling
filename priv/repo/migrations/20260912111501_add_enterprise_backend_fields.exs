defmodule QuantumBilling.Repo.Migrations.AddEnterpriseBackendFields do
  use Ecto.Migration

  def change do
    alter table(:invoices) do
      add :ewb_number, :string
      add :ewb_date, :date
      add :ewb_valid_until, :naive_datetime
      add :distance_km, :integer
      add :transporter_id, :string
      add :transporter_name, :string
      add :vehicle_number, :string
      add :mode_of_transport, :string, default: "Road"

      add :currency, :string, default: "INR"
      add :exchange_rate, :decimal, default: 1.0
      add :export_type, :string, default: "DOMESTIC"
      add :lut_number, :string

      add :razorpay_payment_link_id, :string
      add :razorpay_payment_url, :string
      add :razorpay_payment_id, :string
    end

    create table(:audit_logs) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :string
      add :details, :map, default: "{}"
      add :ip_address, :string

      timestamps(updated_at: false)
    end

    create index(:audit_logs, [:user_id])
    create index(:audit_logs, [:action])
    create index(:audit_logs, [:resource_type, :resource_id])

    create table(:credit_notes) do
      add :note_number, :string, null: false
      add :note_type, :string, null: false, default: "Credit"
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :restrict), null: false
      add :reason, :string
      add :subtotal, :decimal, precision: 12, scale: 2, default: 0.0
      add :tax_total, :decimal, precision: 12, scale: 2, default: 0.0
      add :grand_total, :decimal, precision: 12, scale: 2, default: 0.0
      add :status, :string, default: "Issued"

      timestamps()
    end

    create unique_index(:credit_notes, [:note_number])
    create index(:credit_notes, [:invoice_id])
    create index(:credit_notes, [:client_id])
  end
end
