defmodule QuantumBilling.Repo.TenantMigrations.AddFailureTrackingToRecurringProfiles do
  use Ecto.Migration

  @moduledoc """
  Adds failure tracking and circuit breaker support to recurring billing profiles.

  Tracks consecutive execution failures, the timestamp of the last failure, and
  the failure reason so broken profiles do not loop forever and users are notified.
  """

  def change do
    alter table(:recurring_profiles) do
      add :consecutive_failures, :integer, null: false, default: 0
      add :last_failed_at, :utc_datetime
      add :last_failure_reason, :string
    end
  end
end
