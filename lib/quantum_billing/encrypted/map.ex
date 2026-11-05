defmodule QuantumBilling.Encrypted.Map do
  @moduledoc """
  An encrypted JSON map Ecto type, for the payment webhook ledger.

  Loads with string keys like `:map`. Keyed by `SECRETS_ENCRYPTION_KEY` with
  its own AAD, so other encrypted columns can't be swapped in.
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
