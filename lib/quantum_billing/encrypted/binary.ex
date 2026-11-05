defmodule QuantumBilling.Encrypted.Binary do
  @moduledoc """
  An encrypted Ecto type for TOTP secrets (which must be recoverable, unlike passwords).

  Uses `Encrypted.Cipher` with `TOTP_ENCRYPTION_KEY`. Rotating that key
  invalidates every 2FA enrolment.
  """
  use Ecto.Type

  alias QuantumBilling.Encrypted.Cipher

  @aad "quantum_billing.totp"
  @key :totp_encryption_key

  def type, do: :binary

  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(nil), do: {:ok, nil}
  def cast(_value), do: :error

  def dump(nil), do: {:ok, nil}
  def dump(value) when is_binary(value), do: {:ok, Cipher.encrypt(value, @key, @aad)}
  def dump(_value), do: :error

  def load(nil), do: {:ok, nil}
  def load(value) when is_binary(value), do: Cipher.decrypt(value, @key, @aad)
  def load(_value), do: :error

  def embed_as(_format), do: :self

  def equal?(a, b), do: a == b
end
