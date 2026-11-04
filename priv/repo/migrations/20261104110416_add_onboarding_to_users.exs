defmodule QuantumBilling.Repo.Migrations.AddOnboardingToUsers do
  use Ecto.Migration

  # No backfill: every account, old or new, is shown the onboarding screens
  # once, prefilled with what it already has, and may skip them.
  def change do
    alter table(:users, prefix: "public") do
      add :bio, :text
      add :onboarded_at, :utc_datetime
    end
  end
end
