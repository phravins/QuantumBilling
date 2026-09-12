defmodule QuantumBilling.Repo.Migrations.CreateRecurringProfiles do
  use Ecto.Migration

  def change do
    create table(:recurring_profiles) do
      add :title, :string, null: false
      add :frequency, :string, default: "Monthly", null: false
      add :next_run_date, :date, null: false
      add :status, :string, default: "Active", null: false
      add :auto_send_email, :boolean, default: true, null: false
      add :client_id, references(:clients, on_delete: :nilify_all)
      add :items_json, :text

      timestamps(type: :utc_datetime)
    end

    create index(:recurring_profiles, [:client_id])
    create index(:recurring_profiles, [:next_run_date])
    create index(:recurring_profiles, [:status])
  end
end
