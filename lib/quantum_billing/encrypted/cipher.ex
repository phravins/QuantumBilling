defmodule QuantumBilling.Encrypted.Cipher do
  @moduledoc """
  The AES-256-GCM envelope shared by every encrypted Ecto type.

  One implementation, so `Encrypted.Binary` (two-factor secrets) and
  `Encrypted.Secret` (SMTP and portal credentials) cannot drift apart in how
  they frame, authenticate or key their ciphertext.

  Stored layout, one binary:

      <<iv::16-bytes, tag::16-bytes, ciphertext::binary>>

  The IV is random per encryption, so the same plaintext encrypted twice
  produces different bytes and the column leaks nothing by comparison. GCM is
  authenticated: the tag travels with the ciphertext, so a tampered value fails
  to decrypt rather than quietly decrypting to something else.

  `aad` is the additional authenticated data and differs per type. It binds a
  ciphertext to the purpose it was written for: an SMTP password copied into
  the `totp_secret` column fails its tag check instead of being decrypted by a
  type that was never meant to read it.

  The key is read from application config at call time rather than at compile
  time, so a release picks up the value its environment sets.
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

  @doc """
  Decrypts a stored binary, or returns `:error`.

  `:error` covers both a value that was not written by this cipher and one that
  has been altered since — the caller cannot tell the two apart, and should not
  need to: neither is usable.
  """
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

  # Derived rather than used raw, so a configured value does not have to be
  # exactly 32 bytes for AES-256 to accept it.
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
