defmodule QuantumBilling.Encrypted.Binary do
  @moduledoc """
  An Ecto type that encrypts its value at rest with AES-256-GCM.

  Built for the TOTP secret. Unlike a password, which is stored as a one-way
  hash, a TOTP secret has to be recoverable in order to check codes against it —
  so anyone able to read the column could mint valid codes for that account
  forever. Encrypting it means a database dump alone is not enough; the
  application key is needed too.

  The envelope itself lives in `QuantumBilling.Encrypted.Cipher`; this type
  supplies the key and the additional authenticated data that scope it to
  two-factor secrets.

  The key comes from `TOTP_ENCRYPTION_KEY` (see `config/runtime.exs`). Rotating
  it invalidates every existing enrolment — users would have to enrol again —
  so it is not something to change casually.
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
