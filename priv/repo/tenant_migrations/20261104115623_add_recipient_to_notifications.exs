defmodule QuantumBilling.Repo.Migrations.AddRecipientToNotifications do
  use Ecto.Migration

  # Null means the whole business, which is every notification written so far.
  # A set recipient is one person's: today, a private reminder.
  def change do
    alter table(:notifications) do
      add :recipient_id, references(:users, prefix: "public", on_delete: :delete_all)
    end

    create index(:notifications, [:recipient_id])
  end
end
