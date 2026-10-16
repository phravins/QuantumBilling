defmodule QuantumBilling.Repo.TenantMigrations.DropInstallationRulesFromBusinessSettings do
  use Ecto.Migration

  @moduledoc """
  The IP allowlist, session timeout and mandatory 2FA now live in
  `public.installation_settings`, one set for every business; the move into
  schemas copied business 1's values there. These copies would only drift.

  The old check constraint covered the timeout and the audit retention
  together; dropping the column drops it, so the retention half is put back.
  """

  def up do
    drop constraint(:organization_settings, :organization_settings_security_valid)

    alter table(:organization_settings) do
      remove :allowed_ips
      remove :session_timeout_minutes
      remove :enforce_2fa
    end

    create constraint(:organization_settings, :organization_settings_security_valid,
             check: "audit_retention_days IS NULL OR audit_retention_days > 0"
           )
  end

  def down do
    drop constraint(:organization_settings, :organization_settings_security_valid)

    alter table(:organization_settings) do
      add :allowed_ips, :string
      add :session_timeout_minutes, :integer, default: 60
      add :enforce_2fa, :boolean, default: false
    end

    create constraint(:organization_settings, :organization_settings_security_valid,
             check:
               "(session_timeout_minutes IS NULL OR session_timeout_minutes > 0) AND " <>
                 "(audit_retention_days IS NULL OR audit_retention_days > 0)"
           )
  end
end
