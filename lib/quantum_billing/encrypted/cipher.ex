defmodule QuantumBilling.Encrypted.Cipher do
  @moduledoc """
  AES-256-GCM shared by the encrypted Ecto types (`Encrypted.Binary`, `Encrypted.Secret`).

  Stored as `<<iv::16-bytes, tag::16-bytes, ciphertext::binary>>` with a random
  IV per write. `aad` differs per type, so a value copied into another
  type's column fails to decrypt. The key is read from config at runtime.
  """

  @iv_bytes 16
  @tag_bytes 16

  @doc """
  Encrypts `plaintext` under the key at `config_key`, bound to `aad`.
  """
  def encrypt(plaintext, config_key, aad) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(config_key), iv, plaintext, aad, true)

    iv <> tag <> ciphertext
  end

  @doc "Decrypts a stored binary, or `:error` if it is foreign or has been tampered with."
  def decrypt(
        <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>,
        config_key,
        aad
      ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key(config_key),
           iv,
           ciphertext,
           aad,
           tag,
           false
         ) do
      :error -> :error
      plaintext -> {:ok, plaintext}
    end
  end

  # Anything shorter than an IV and a tag was not written by this cipher.
  def decrypt(_value, _config_key, _aad), do: :error

  # Derived so the configured key need not be exactly 32 bytes.
  defp key(config_key) do
    :crypto.hash(:sha256, fetch_key!(config_key))
  end

  defp fetch_key!(config_key) do
    case Application.fetch_env(:quantum_billing, config_key) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        key

      _missing ->
        raise """
        #{env_var(config_key)} is not configured.

        Encrypted columns cannot be read or written without it. Set it in your
        environment (or .env locally) and restart. Generate one with:

            mix phx.gen.secret

        Changing this value makes every value already encrypted under it
        unreadable.
        """
    end
  end

  defp env_var(:totp_encryption_key), do: "TOTP_ENCRYPTION_KEY"
  defp env_var(:secrets_encryption_key), do: "SECRETS_ENCRYPTION_KEY"
  defp env_var(other), do: other |> to_string() |> String.upcase()
end
