defmodule QuantumBilling.Repo.TenantMigrations.AddPaymentReminders do
  use Ecto.Migration

  def change do
    alter table(:organization_settings) do
      add :payment_reminders_enabled, :boolean, null: false, default: false

      add :payment_reminder_days, {:array, :integer},
        null: false,
        default: [-3, 0, 7]
    end

    alter table(:clients) do
      add :reminders_opt_out, :boolean, null: false, default: false
    end

    create table(:payment_reminders) do
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false
      add :step, :integer, null: false
      add :sent_at, :utc_datetime, null: false
    end

    create unique_index(:payment_reminders, [:invoice_id, :step])
    create index(:payment_reminders, [:invoice_id])
  end
end
