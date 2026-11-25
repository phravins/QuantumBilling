defmodule QuantumBilling.Repo.TenantMigrations.AddRazorpayWebhookSecretToOrganizationSettings do
  use Ecto.Migration

  @moduledoc """
  The secret Razorpay signs this business's incoming webhooks with. Each
  business has its own, so one firm cannot sign deliveries for another's URL.
  `bytea`: AES-256-GCM ciphertext written by `QuantumBilling.Encrypted.Secret`.
  """

  def change do
    alter table(:organization_settings) do
      add :razorpay_webhook_secret, :binary
    end
  end
end
