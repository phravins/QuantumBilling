defmodule QuantumBilling.Encrypted.Secret do
  @moduledoc """
  An Ecto type for credentials the app presents to other systems (SMTP,
  Razorpay, IRP, webhook signing), encrypted with `SECRETS_ENCRYPTION_KEY`.

  Keyed separately from `Encrypted.Binary`. An empty string is stored as `NULL`,
  so a cleared field means "not configured".
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
