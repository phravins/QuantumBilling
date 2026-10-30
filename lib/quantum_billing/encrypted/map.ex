defmodule QuantumBilling.Encrypted.Map do
  @moduledoc """
  An Ecto type for a JSON map encrypted at rest with AES-256-GCM.

  Built for the webhook ledger. A payment provider's event describes a real
  person's payment, so even trimmed to what reconciliation needs, the row should
  not be readable from a database dump on its own.

  Encoded as JSON, so it loads back with string keys exactly as a `:map` field
  would. Keyed with `SECRETS_ENCRYPTION_KEY`, under its own additional
  authenticated data, so a ciphertext from another encrypted column cannot be
  substituted for one of these.
  """
  use Ecto.Type

  alias QuantumBilling.Encrypted.Cipher

  @aad "quantum_billing.webhook_payload"
  @key :secrets_encryption_key

  def type, do: :binary

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_map(value), do: {:ok, value}
  def cast(_value), do: :error

  def dump(nil), do: {:ok, nil}
  def dump(value) when is_map(value), do: {:ok, encrypt(value)}
  def dump(_value), do: :error

  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    with {:ok, json} <- Cipher.decrypt(value, @key, @aad),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _unreadable -> :error
    end
  end

  def load(_value), do: :error

  def embed_as(_format), do: :self

  def equal?(a, b), do: a == b

  @doc "Encrypts a map the way this type stores it; used by the backfill migration."
  def encrypt(map) when is_map(map), do: map |> Jason.encode!() |> Cipher.encrypt(@key, @aad)
end
