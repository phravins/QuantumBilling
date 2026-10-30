defmodule QuantumBilling.Repo.Migrations.CreateComplianceTasks do
  use Ecto.Migration

  def change do
    create table(:compliance_tasks) do
      add :title, :string, null: false
      add :notes, :text
      add :category, :string, null: false, default: "other"
      add :due_date, :date, null: false
      add :kind, :string, null: false, default: "task"
      add :status, :string, null: false, default: "open"
      add :completed_at, :utc_datetime
      add :remind_days_before, :integer, null: false, default: 1
      add :reminded_at, :utc_datetime
      add :created_by_id, references(:users, prefix: "public", on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:compliance_tasks, [:due_date])
    create index(:compliance_tasks, [:status])
  end
end
