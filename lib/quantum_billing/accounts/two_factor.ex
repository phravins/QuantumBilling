defmodule QuantumBilling.Accounts.TwoFactor do
  @moduledoc """
  Time-based one-time passwords (RFC 6238), as used by Google Authenticator,
  Microsoft Authenticator, 1Password and the rest.

  ## Enrolment is two steps on purpose

  `start_enrolment/1` stores a secret but leaves `totp_confirmed_at` empty, and
  only `confirm_enrolment/2` — which requires a working code — turns 2FA on.
  Enabling on the secret alone would lock out anyone who opened the setup
  screen, never scanned the QR, and closed the tab.

  ## Replay protection

  A TOTP code is valid for its whole 30-second window, so the same six digits
  could otherwise be presented twice. `totp_last_used_at` records the timestamp
  of the last accepted code and `NimbleTOTP` refuses anything from that window
  or earlier.

  ## Recovery codes

  Ten, single use, hashed with the same algorithm as passwords and shown in
  plain text exactly once. They are the only way back into an account whose
  authenticator is gone — there is no admin override — which is why they are
  issued automatically at enrolment rather than being optional.
  """

  import Ecto.Changeset

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Repo

  @issuer "QuantumBilling"
  @recovery_code_count 10

  # Roughly 40 bits of entropy per code. Ambiguous characters are left out so a
  # code read off a screen and typed back in does not fail on 0 versus O.
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

  @doc """
  Generates and stores a fresh secret, leaving 2FA switched off.

  Called each time the setup screen is opened, so an abandoned enrolment never
  leaves a stale secret that a later QR would not match.
  """
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
  Turns 2FA on once `code` proves the authenticator is set up correctly.

  Returns `{:ok, user, recovery_codes}` with the codes in plain text — the only
  time they exist outside a hash. `{:error, :invalid_code}` leaves 2FA off.
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
  Checks a code at sign-in. Accepts either a TOTP code or a recovery code.

  Returns `{:ok, user}`, and for a recovery code also consumes it so it cannot
  be used again. `{:error, :invalid_code}` otherwise.
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

  @doc """
  Issues a fresh set of recovery codes, invalidating the previous ones.

  Returns `{:ok, user, codes}` with the codes in plain text.
  """
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

  @doc """
  The `otpauth://` URI an authenticator app reads.

  The label carries the issuer twice — once as a prefix and once as a
  parameter — which is what makes both Google Authenticator and Microsoft
  Authenticator show the account grouped under the right name.
  """
  def otpauth_uri(%User{totp_secret: secret, email: email}) when is_binary(secret) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{email}", secret, issuer: @issuer)
  end

  @doc """
  The enrolment QR as inline SVG.

  Rendered here rather than by an image service, so the secret never leaves the
  application.
  """
  def qr_svg(%User{} = user) do
    user
    |> otpauth_uri()
    |> EQRCode.encode()
    |> EQRCode.svg(width: 200, background_color: "#ffffff", color: "#18181b")
  end

  @doc """
  The secret in the base-32 form an app expects when typed in by hand, in
  four-character groups.
  """
  def manual_entry_key(%User{totp_secret: secret}) when is_binary(secret) do
    secret
    |> Base.encode32(padding: false)
    |> String.to_charlist()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &to_string/1)
  end

  def manual_entry_key(_user), do: nil

  @doc "The issuer name shown in the authenticator app."
  def issuer, do: @issuer

  # ── Internals ──────────────────────────────────────────────────────────────

  defp valid_totp?(secret, code, last_used_at) when is_binary(secret) and is_binary(code) do
    # A six-digit check first: NimbleTOTP would return false anyway, but this
    # keeps a recovery code from being pointlessly compared against the secret.
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

  # Each code is hashed, so finding the match means checking the candidate
  # against every stored hash. `Pbkdf2.no_user_verify/0` on the empty case keeps
  # the timing similar whether or not codes exist.
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

  # Accepts the code however it was typed back: lower case, with the hyphen a
  # user might add, or with stray spaces.
  defp normalise_recovery_code(code) do
    code
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
  end
end
