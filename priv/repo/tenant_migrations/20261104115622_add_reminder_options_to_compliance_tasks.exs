defmodule QuantumBilling.Repo.Migrations.AddReminderOptionsToComplianceTasks do
  use Ecto.Migration

  # Every column has a default or is nullable, so existing tasks keep working
  # exactly as before: a built-in category, no repeat, shared with the team,
  # reminded on the day, in the app only.
  def change do
    alter table(:compliance_tasks) do
      add :custom_category, :string
      add :repeat, :string, null: false, default: "none"
      add :private, :boolean, null: false, default: false
      add :remind_at, :time
      add :email_reminder, :boolean, null: false, default: false
    end

    create index(:compliance_tasks, [:created_by_id])
  end
end
