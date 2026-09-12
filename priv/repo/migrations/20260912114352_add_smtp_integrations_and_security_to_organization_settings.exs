defmodule QuantumBilling.Repo.Migrations.AddSmtpIntegrationsAndSecurityToOrganizationSettings do
  use Ecto.Migration

  def change do
    alter table(:organization_settings) do
      # SMTP Settings
      add :smtp_host, :string
      add :smtp_port, :integer, default: 587
      add :smtp_username, :string
      add :smtp_password, :string
      add :smtp_ssl, :boolean, default: false
      add :smtp_from_email, :string
      add :smtp_from_name, :string

      # Integrations Credentials
      add :razorpay_key_id, :string
      add :razorpay_key_secret, :string
      add :irp_username, :string
      add :irp_password, :string
      add :irp_client_id, :string
      add :webhook_url, :string
      add :webhook_secret, :string

      # Security Settings
      add :allowed_ips, :string
      add :session_timeout_minutes, :integer, default: 60
      add :enforce_2fa, :boolean, default: false
      add :audit_retention_days, :integer, default: 90
    end
  end
end
