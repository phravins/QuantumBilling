defmodule QuantumBilling.Repo.Migrations.AddTwoFactorToUsers do
  use Ecto.Migration

  @moduledoc """
  Two factor authentication (TOTP) per user.

  `totp_secret` holds ciphertext, not the secret — see
  `QuantumBilling.Encrypted.Binary`.
  """

  def change do
    alter table(:users) do
      # Encrypted at rest. Present but unconfirmed means enrolment was started
      # and abandoned.
      add :totp_secret, :binary

      # This, not the secret, is what "2FA is on" means. Gating login on the
      # secret alone would lock out anyone who opened the setup screen and
      # walked away without scanning the code.
      add :totp_confirmed_at, :utc_datetime

      # Replay protection. A TOTP code stays valid for its whole 30-second
      # window, so without this the same code could be used twice.
      add :totp_last_used_at, :utc_datetime

      # Hashed, like passwords, and single use. Plain text is shown to the user
      # exactly once at generation.
      add :recovery_codes, {:array, :string}, null: false, default: []
    end
  end
end
