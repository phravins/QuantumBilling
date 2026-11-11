defmodule QuantumBilling.Accounts.TwoFactor do
  @moduledoc """
  Time-based one-time passwords (RFC 6238).

  `start_enrolment/1` stores a secret; only `confirm_enrolment/2`, with a valid
  code, turns 2FA on. `totp_last_used_at` blocks replaying a code within its
  window. Ten single-use recovery codes are hashed and shown once.
  """

  import Ecto.Changeset

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Repo

  @issuer "QuantumBilling"
  @recovery_code_count 10

  # Ambiguous characters (0/O, 1/I) are left out.
  @recovery_alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @recovery_code_length 8

  @doc """
  Whether `user` has completed enrolment. A stored secret alone is not enough.
  """
  def enabled?(%User{totp_confirmed_at: nil}), do: false
  def enabled?(%User{}), do: true
  def enabled?(nil), do: false

  @doc """
  Whether `user` has started but not finished enrolment.
  """
  def pending?(%User{totp_secret: secret, totp_confirmed_at: nil}) when is_binary(secret),
    do: true

  def pending?(_user), do: false

  @doc "Generates and stores a fresh secret, leaving 2FA off. Runs each time setup opens."
  def start_enrolment(%User{} = user) do
    user
    |> change(%{
      totp_secret: NimbleTOTP.secret(),
      totp_confirmed_at: nil,
      totp_last_used_at: nil,
      recovery_codes: []
    })
    |> Repo.update()
  end

  @doc """
  Turns 2FA on once `code` checks out: `{:ok, user, recovery_codes}` or `{:error, :invalid_code}`.
  """
  def confirm_enrolment(%User{totp_secret: secret} = user, code) when is_binary(secret) do
    if valid_totp?(secret, code, user.totp_last_used_at) do
      {plain, hashed} = generate_recovery_codes()
      now = DateTime.utc_now(:second)

      {:ok, user} =
        user
        |> change(%{
          totp_confirmed_at: now,
          totp_last_used_at: now,
          recovery_codes: hashed
        })
        |> Repo.update()

      {:ok, user, plain}
    else
      {:error, :invalid_code}
    end
  end

  def confirm_enrolment(%User{}, _code), do: {:error, :not_enrolling}

  @doc """
  Checks a TOTP or recovery code at sign-in: `{:ok, user}` or `{:error, :invalid_code}`. Recovery codes are consumed.
  """
  def verify(%User{} = user, code) do
    code = String.trim(code)

    cond do
      not enabled?(user) ->
        {:error, :not_enabled}

      valid_totp?(user.totp_secret, code, user.totp_last_used_at) ->
        mark_used(user)

      true ->
        consume_recovery_code(user, code)
    end
  end

  @doc "Issues fresh recovery codes, replacing the old ones: `{:ok, user, codes}`."
  def regenerate_recovery_codes(%User{} = user) do
    {plain, hashed} = generate_recovery_codes()

    {:ok, user} =
      user
      |> change(%{recovery_codes: hashed})
      |> Repo.update()

    {:ok, user, plain}
  end

  @doc """
  Switches 2FA off and discards the secret and every recovery code.
  """
  def disable(%User{} = user) do
    user
    |> change(%{
      totp_secret: nil,
      totp_confirmed_at: nil,
      totp_last_used_at: nil,
      recovery_codes: []
    })
    |> Repo.update()
  end

  @doc """
  How many recovery codes remain unused.
  """
  def recovery_codes_remaining(%User{recovery_codes: codes}), do: length(codes || [])

  @doc "The `otpauth://` URI an authenticator app reads, with the issuer as prefix and parameter."
  def otpauth_uri(%User{totp_secret: secret, email: email}) when is_binary(secret) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{email}", secret, issuer: @issuer)
  end

  @doc "The enrolment QR as inline SVG, rendered locally so the secret never leaves the app."
  def qr_svg(%User{} = user) do
    user
    |> otpauth_uri()
    |> EQRCode.encode()
    |> EQRCode.svg(width: 200, background_color: "#ffffff", color: "#18181b")
  end

  @doc "The secret in base-32, in four-character groups, for typing in by hand."
  def manual_entry_key(%User{totp_secret: secret}) when is_binary(secret) do
    secret
    |> Base.encode32(padding: false)
    |> String.to_charlist()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &to_string/1)
  end

  def manual_entry_key(_user), do: nil

  defp valid_totp?(secret, code, last_used_at) when is_binary(secret) and is_binary(code) do
    if Regex.match?(~r/^\d{6}$/, code) do
      NimbleTOTP.valid?(secret, code, since: last_used_at)
    else
      false
    end
  end

  defp valid_totp?(_secret, _code, _last_used_at), do: false

  defp mark_used(user) do
    user
    |> change(%{totp_last_used_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  # no_user_verify/0 keeps the timing similar when no codes exist.
  defp consume_recovery_code(%User{recovery_codes: []}, _code) do
    Pbkdf2.no_user_verify()
    {:error, :invalid_code}
  end

  defp consume_recovery_code(%User{recovery_codes: codes} = user, code) do
    normalised = normalise_recovery_code(code)

    case Enum.split_with(codes, &Pbkdf2.verify_pass(normalised, &1)) do
      {[], _rest} ->
        {:error, :invalid_code}

      {[_used | _], remaining} ->
        user
        |> change(%{recovery_codes: remaining})
        |> Repo.update()
    end
  end

  defp generate_recovery_codes do
    plain = for _ <- 1..@recovery_code_count, do: random_recovery_code()
    {plain, Enum.map(plain, &Pbkdf2.hash_pwd_salt(normalise_recovery_code(&1)))}
  end

  defp random_recovery_code do
    1..@recovery_code_length
    |> Enum.map(fn _ -> Enum.random(@recovery_alphabet) end)
    |> to_string()
  end

  defp normalise_recovery_code(code) do
    code
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
  end
end
