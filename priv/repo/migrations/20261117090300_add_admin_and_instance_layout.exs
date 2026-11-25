defmodule QuantumBilling.Repo.Migrations.AddAdminAndInstanceLayout do
  use Ecto.Migration

  # Installation-wide: the super admin flag, maintenance mode and the main
  # sidebar's order. None of these belong to one business.
  def change do
    alter table(:users, prefix: "public") do
      add :is_admin, :boolean, null: false, default: false
    end

    alter table(:installation_settings, prefix: "public") do
      add :maintenance_mode, :boolean, null: false, default: false
      add :nav_layout, :map, null: false, default: %{}
    end
  end
end
