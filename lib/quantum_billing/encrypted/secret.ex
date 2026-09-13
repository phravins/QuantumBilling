defmodule QuantumBilling.Encrypted.Secret do
  @moduledoc """
  An Ecto type for the credentials the organisation hands to other systems:
  the SMTP password, the Razorpay key secret, the IRP password and the webhook
  signing secret.

  These are not passwords to check — they have to be presented verbatim to a
  mail relay or an API, so they cannot be hashed. Encrypting them means the
  settings table is no longer a list of usable credentials for anyone who can
  read the database: a dump on its own gets an attacker nothing without
  `SECRETS_ENCRYPTION_KEY` from the application environment.

  Separate from `Encrypted.Binary`, which holds two-factor secrets, in both key
  and additional authenticated data. Rotating one does not invalidate the
  other, and neither type can decrypt the other's columns.

  ## Blank values

  An empty string means "not configured" rather than "a secret that happens to
  be empty", so it is stored as `NULL`. Otherwise clearing a field in the
  settings form would write ciphertext that decrypts to `""`, and every
  `nil`-check downstream would start seeing a configured credential.
  """
  use Ecto.Type

  alias QuantumBilling.Encrypted.Cipher

  @aad "quantum_billing.secret"
  @key :secrets_encryption_key

  def type, do: :binary

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  def dump(nil), do: {:ok, nil}
  def dump(""), do: {:ok, nil}
  def dump(value) when is_binary(value), do: {:ok, Cipher.encrypt(value, @key, @aad)}
  def dump(_value), do: :error

  def load(nil), do: {:ok, nil}
  def load(value) when is_binary(value), do: Cipher.decrypt(value, @key, @aad)
  def load(_value), do: :error

  def embed_as(_format), do: :self

  def equal?(a, b), do: a == b
end
