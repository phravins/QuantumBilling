defmodule QuantumBilling.Accounts.TwoFactorTest do
  use QuantumBilling.DataCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts.TwoFactor

  defp enrolling(_context) do
    {:ok, user} = TwoFactor.start_enrolment(user_fixture())
    %{user: user}
  end

  defp enrolled(_context) do
    {:ok, user} = TwoFactor.start_enrolment(user_fixture())
    {:ok, user, codes} = TwoFactor.confirm_enrolment(user, current_code(user))
    # Clear the replay marker so tests can verify without fighting their own
    # enrolment code.
    %{user: %{user | totp_last_used_at: nil}, recovery_codes: codes}
  end

  defp current_code(user), do: NimbleTOTP.verification_code(user.totp_secret)

  describe "enabled?/1 and pending?/1" do
    test "a fresh account has neither" do
      user = user_fixture()

      refute TwoFactor.enabled?(user)
      refute TwoFactor.pending?(user)
    end

    setup :enrolling

    test "a started enrolment is pending, not enabled", %{user: user} do
      # This is the distinction that stops a user who opened the setup screen
      # and walked away from being locked out of their own account.
      assert TwoFactor.pending?(user)
      refute TwoFactor.enabled?(user)
    end
  end

  describe "start_enrolment/1" do
    setup :enrolling

    test "stores a secret without switching 2FA on", %{user: user} do
      assert is_binary(user.totp_secret)
      assert user.totp_confirmed_at == nil
      assert user.recovery_codes == []
    end

    test "starting again replaces the secret", %{user: user} do
      {:ok, restarted} = TwoFactor.start_enrolment(user)

      refute restarted.totp_secret == user.totp_secret
    end
  end

  describe "confirm_enrolment/2" do
    setup :enrolling

    test "a wrong code leaves 2FA off", %{user: user} do
      assert {:error, :invalid_code} = TwoFactor.confirm_enrolment(user, "000000")
      refute TwoFactor.enabled?(Repo.reload(user))
    end

    test "a correct code turns it on and issues ten recovery codes", %{user: user} do
      assert {:ok, user, codes} = TwoFactor.confirm_enrolment(user, current_code(user))

      assert TwoFactor.enabled?(user)
      assert length(codes) == 10
      assert length(Enum.uniq(codes)) == 10
    end

    test "the recovery codes are stored hashed, never in plain text", %{user: user} do
      {:ok, user, codes} = TwoFactor.confirm_enrolment(user, current_code(user))

      for code <- codes do
        refute code in user.recovery_codes
      end

      assert Enum.all?(user.recovery_codes, &String.starts_with?(&1, "$pbkdf2"))
    end

    test "cannot confirm without having started" do
      assert {:error, :not_enrolling} = TwoFactor.confirm_enrolment(user_fixture(), "123456")
    end
  end

  describe "verify/2 with a TOTP code" do
    setup :enrolled

    test "accepts the current code", %{user: user} do
      assert {:ok, _user} = TwoFactor.verify(user, current_code(user))
    end

    test "rejects a wrong code", %{user: user} do
      assert {:error, :invalid_code} = TwoFactor.verify(user, "000000")
    end

    test "rejects the same code twice", %{user: user} do
      # A code is valid for its whole 30-second window, so without replay
      # protection one observed over a shoulder would work again.
      code = current_code(user)

      assert {:ok, user} = TwoFactor.verify(user, code)
      assert {:error, :invalid_code} = TwoFactor.verify(user, code)
    end

    test "rejects a code from an earlier window", %{user: user} do
      past = System.os_time(:second) - 60
      old_code = NimbleTOTP.verification_code(user.totp_secret, time: past)

      assert {:error, :invalid_code} = TwoFactor.verify(user, old_code)
    end

    test "rejects anything that is not six digits", %{user: user} do
      for junk <- ["", "12345", "1234567", "abcdef", "12 34 56"] do
        assert {:error, :invalid_code} = TwoFactor.verify(user, junk)
      end
    end

    test "refuses when 2FA is not enabled" do
      assert {:error, :not_enabled} = TwoFactor.verify(user_fixture(), "123456")
    end
  end

  describe "verify/2 with a recovery code" do
    setup :enrolled

    test "accepts one and consumes it", %{user: user, recovery_codes: [code | _]} do
      assert {:ok, user} = TwoFactor.verify(user, code)
      assert TwoFactor.recovery_codes_remaining(user) == 9

      assert {:error, :invalid_code} = TwoFactor.verify(user, code)
    end

    test "consuming one leaves the others working", %{user: user, recovery_codes: codes} do
      [first, second | _] = codes

      {:ok, user} = TwoFactor.verify(user, first)
      assert {:ok, user} = TwoFactor.verify(user, second)
      assert TwoFactor.recovery_codes_remaining(user) == 8
    end

    test "is forgiving about how it is typed back", %{user: user, recovery_codes: [code | _]} do
      messy = code |> String.downcase() |> String.replace(~r/(.{4})/, "\\1-")

      assert {:ok, _user} = TwoFactor.verify(user, messy)
    end

    test "rejects an invented code", %{user: user} do
      assert {:error, :invalid_code} = TwoFactor.verify(user, "ZZZZZZZZ")
    end

    test "rejects anything once the codes are exhausted", %{user: user, recovery_codes: codes} do
      user = Enum.reduce(codes, user, fn code, acc -> elem(TwoFactor.verify(acc, code), 1) end)

      assert TwoFactor.recovery_codes_remaining(user) == 0
      assert {:error, :invalid_code} = TwoFactor.verify(user, hd(codes))
    end
  end

  describe "regenerate_recovery_codes/1" do
    setup :enrolled

    test "issues new ones and invalidates the old", %{user: user, recovery_codes: [old | _]} do
      assert {:ok, user, new_codes} = TwoFactor.regenerate_recovery_codes(user)

      assert length(new_codes) == 10
      refute old in new_codes
      assert {:error, :invalid_code} = TwoFactor.verify(user, old)
      assert {:ok, _user} = TwoFactor.verify(user, hd(new_codes))
    end
  end

  describe "disable/1" do
    setup :enrolled

    test "clears the secret and every recovery code", %{user: user, recovery_codes: [code | _]} do
      assert {:ok, user} = TwoFactor.disable(user)

      refute TwoFactor.enabled?(user)
      assert user.totp_secret == nil
      assert user.recovery_codes == []
      assert {:error, :not_enabled} = TwoFactor.verify(user, code)
    end
  end

  describe "enrolment details the authenticator apps read" do
    setup :enrolling

    test "the otpauth URI carries the issuer and the account", %{user: user} do
      uri = TwoFactor.otpauth_uri(user)

      assert String.starts_with?(uri, "otpauth://totp/")
      assert uri =~ "issuer=QuantumBilling"
      assert uri =~ "secret="
      # The label is prefixed with the issuer too, which is what groups the
      # entry correctly in Google and Microsoft Authenticator.
      assert uri =~ "QuantumBilling"
    end

    test "the secret in the URI is the real one, base-32 encoded", %{user: user} do
      uri = TwoFactor.otpauth_uri(user)
      [_, encoded] = Regex.run(~r/secret=([A-Z2-7]+)/, uri)

      assert Base.decode32!(encoded, padding: false) == user.totp_secret
    end

    test "the QR is inline SVG, so the secret never leaves the app", %{user: user} do
      svg = TwoFactor.qr_svg(user)

      assert svg =~ "<svg"
      # Drawn as rects, not fetched: no <image> and no external reference, so
      # the secret is never handed to a QR service. (The w3.org strings in the
      # markup are XML namespaces — identifiers, not requests.)
      refute svg =~ "<image"
      refute svg =~ "xlink:href=\"http"
      # And the secret itself is not sitting in the markup in readable form.
      refute svg =~ Base.encode32(user.totp_secret, padding: false)
    end

    test "the manual key decodes back to the secret", %{user: user} do
      key = TwoFactor.manual_entry_key(user)

      assert key =~ ~r/^[A-Z2-7 ]+$/
      assert key |> String.replace(" ", "") |> Base.decode32!(padding: false) == user.totp_secret
    end
  end

  describe "storage" do
    setup :enrolled

    test "the secret is unreadable in the database", %{user: user} do
      %{rows: [[stored]]} =
        Repo.query!("select totp_secret from users where id = $1", [user.id])

      assert is_binary(stored)
      # Ciphertext, not the secret: someone with a database dump cannot mint
      # codes from this.
      refute stored == user.totp_secret
      refute String.contains?(stored, user.totp_secret)
    end
  end
end
