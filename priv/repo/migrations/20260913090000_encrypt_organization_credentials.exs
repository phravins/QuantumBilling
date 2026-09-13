defmodule QuantumBilling.Repo.Migrations.EncryptOrganizationCredentials do
  use Ecto.Migration

  @moduledoc """
  Moves the stored integration credentials into encrypted columns.

  The SMTP password, the Razorpay key secret, the IRP password and the webhook
  signing secret were `varchar`, which made `organization_settings` a list of
  usable credentials for anyone who could read the database — a backup, a
  replica, a support query. They are now `bytea` holding AES-256-GCM
  ciphertext, written and read by `QuantumBilling.Encrypted.Secret`.

  ## The existing values are dropped rather than converted

  Encryption happens in the application, with a key the database does not have,
  so there is no SQL that could re-write the old values in place. Copying the
  plaintext into the new column would leave it readable and defeat the point.
  The columns are therefore replaced empty and the credentials have to be
  entered again in Settings once — which is also the safe assumption for
  anything that has been sitting in a plaintext column.

  Everything else in these sections (host, port, username, key id, webhook URL)
  stays as it is: those are configuration, not secrets, and the settings form
  needs to show them.
  """

  @credentials [:smtp_password, :razorpay_key_secret, :irp_password, :webhook_secret]

  def up do
    for column <- @credentials do
      alter table(:organization_settings) do
        remove column
        add column, :binary
      end
    end
  end

  def down do
    for column <- @credentials do
      alter table(:organization_settings) do
        remove column
        add column, :string
      end
    end
  end
end
