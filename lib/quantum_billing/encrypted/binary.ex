defmodule QuantumBilling.Encrypted.Binary do
  @moduledoc """
  An Ecto type that encrypts its value at rest with AES-256-GCM.

  Built for the TOTP secret. Unlike a password, which is stored as a one-way
  hash, a TOTP secret has to be recoverable in order to check codes against it —
  so anyone able to read the column could mint valid codes for that account
  forever. Encrypting it means a database dump alone is not enough; the
  application key is needed too.

  GCM is authenticated encryption: the tag is stored with the ciphertext, so a
  value that has been tampered with fails to decrypt rather than quietly
  producing a different secret.

  Stored layout, one binary:

      <<iv::16-bytes, tag::16-bytes, ciphertext::binary>>

  The IV is random per encryption, so encrypting the same secret twice produces
  different ciphertext and the column leaks nothing by comparison.

  The key comes from `TOTP_ENCRYPTION_KEY` (see `config/runtime.exs`). Rotating
  it invalidates every existing enrolment — users would have to enrol again —
  so it is not something to change casually.
  """
  use Ecto.Type

  @aad "quantum_billing.totp"
  @iv_bytes 16
  @tag_bytes 16

  def type, do: :binary

  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(nil), do: {:ok, nil}
  def cast(_value), do: :error

  def dump(nil), do: {:ok, nil}

  def dump(value) when is_binary(value) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, value, @aad, true)

    {:ok, iv <> tag <> ciphertext}
  end

  def dump(_value), do: :error

  def load(nil), do: {:ok, nil}

  def load(<<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      :error -> :error
      plaintext -> {:ok, plaintext}
    end
  end

  # Anything that is not at least an IV and a tag was not written by this type.
  def load(_value), do: :error

  def embed_as(_format), do: :self

  def equal?(a, b), do: a == b

  # Derived rather than used raw, so the configured value does not have to be
  # exactly 32 bytes for AES-256 to accept it.
  defp key do
    :crypto.hash(:sha256, fetch_key!())
  end

  defp fetch_key! do
    case Application.fetch_env(:quantum_billing, :totp_encryption_key) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        key

      _missing ->
        raise """
        TOTP_ENCRYPTION_KEY is not configured.

        Two factor authentication cannot store secrets without it. Set it in
        your environment (or .env locally) and restart. Generate one with:

            mix phx.gen.secret

        Changing this value invalidates every existing 2FA enrolment.
        """
    end
  end
end
