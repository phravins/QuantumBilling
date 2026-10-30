defmodule QuantumBilling.Repo.Migrations.AddBannerSeedToUsers do
  use Ecto.Migration

  # Null means "derive the scene from the user id"; set only by a shuffle.
  def change do
    alter table(:users) do
      add :banner_seed, :bigint
    end
  end
end
