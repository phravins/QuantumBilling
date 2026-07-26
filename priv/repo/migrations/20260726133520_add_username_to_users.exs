defmodule QuantumBilling.Repo.Migrations.AddUsernameToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Nullable so accounts created before sign-up collected a username keep
      # working; the requirement is enforced by the registration changeset.
      add :username, :citext
    end

    create unique_index(:users, [:username])
  end
end
