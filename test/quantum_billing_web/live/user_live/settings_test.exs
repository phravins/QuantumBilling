defmodule QuantumBillingWeb.UserLive.SettingsTest do
  use QuantumBillingWeb.ConnCase, async: true

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.TwoFactor
  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Account Settings"
      assert html =~ "Profile Information"
      assert html =~ "Email Address"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    # This test changed meaning deliberately. The page used to carry
    # `on_mount :require_sudo_mode`, so any visit more than ten minutes after
    # sign-in redirected to the login screen — you could not look at your own
    # name. The gate now sits on the sensitive actions instead.
    test "stays open without recent sign-in, but refuses a password change", %{conn: conn} do
      user = user_fixture()

      conn =
        log_in_user(conn, user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )

      # The page itself loads.
      {:ok, lv, html} = live(conn, ~p"/users/settings?tab=password")
      assert html =~ "Account Settings"

      # The sensitive action is refused rather than crashing.
      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "a-brand-new-password",
            "password_confirmation" => "a-brand-new-password"
          }
        })
        |> render_submit()

      assert result =~ "sign in again"
      refute Accounts.get_user_by_email_and_password(user.email, "a-brand-new-password")
    end

    test "refuses an email change without recent sign-in", %{conn: conn} do
      user = user_fixture()

      conn =
        log_in_user(conn, user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
        |> render_submit()

      assert result =~ "sign in again"
      # The address is unchanged.
      assert Accounts.get_user_by_email(user.email)
    end

    test "editing the profile does not need recent sign-in", %{conn: conn} do
      user = user_fixture()

      conn =
        log_in_user(conn, user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#profile_form", %{"user" => %{"full_name" => "Priya Sharma"}})
        |> render_submit()

      assert result =~ "Profile updated."
      assert Accounts.get_user_by_email(user.email).full_name == "Priya Sharma"
    end
  end

  describe "profile form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "saves name, designation and phone together", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#profile_form", %{
        "user" => %{
          "full_name" => "Priya Sharma",
          "designation" => "GST Officer",
          "phone" => "+91 98765 43210"
        }
      })
      |> render_submit()

      reloaded = Accounts.get_user_by_email(user.email)
      assert reloaded.full_name == "Priya Sharma"
      assert reloaded.designation == "GST Officer"
      assert reloaded.phone == "+91 98765 43210"
    end

    test "the saved name and designation reach the sidebar", %{conn: conn, user: user} do
      {:ok, _} =
        Accounts.update_user_profile(user, %{
          full_name: "Priya Sharma",
          designation: "GST Officer"
        })

      {:ok, _lv, html} = live(conn, ~p"/users/settings")

      assert html =~ "Priya Sharma"
      assert html =~ "GST Officer"
      # Initials come from the name now, not the first two letters of the email.
      assert html =~ ">\n            PS\n          <" or html =~ "PS"
    end

    test "rejects a phone number with letters in it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#profile_form", %{"user" => %{"phone" => "call me maybe"}})
        |> render_submit()

      assert result =~ "may only contain digits"
    end
  end

  describe "tabs" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, user_fixture())}
    end

    test "default to Profile", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings")

      assert html =~ "Profile Information"
      refute html =~ "Choose a strong password"
    end

    test "the password tab is linkable and survives a reload", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings?tab=password")

      assert html =~ "Choose a strong password"
      refute html =~ "Profile Information"
    end

    test "two factor authentication offers enrolment", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings?tab=two_factor")

      assert html =~ "Set up two-factor authentication"
      refute html =~ "not available yet"
    end
  end

  describe "two factor enrolment" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "starting it shows a QR and the manual key", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings?tab=two_factor")

      html = lv |> element("button[phx-click=start_totp_enrolment]") |> render_click()

      assert html =~ "Scan this with your authenticator app"
      assert html =~ "<svg"
      assert html =~ "enter this key by hand"
      # Not on yet — a secret alone must never gate a login.
      refute html =~ "Turn off"
    end

    test "a wrong code leaves it switched off", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings?tab=two_factor")
      lv |> element("button[phx-click=start_totp_enrolment]") |> render_click()

      html =
        lv
        |> form("form[phx-submit=confirm_totp]", %{"totp" => %{"code" => "000000"}})
        |> render_submit()

      assert html =~ "not valid"
      refute TwoFactor.enabled?(Accounts.get_user(user.id))
    end

    test "a correct code turns it on and shows the recovery codes once", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings?tab=two_factor")
      lv |> element("button[phx-click=start_totp_enrolment]") |> render_click()

      code = NimbleTOTP.verification_code(Accounts.get_user(user.id).totp_secret)

      html =
        lv
        |> form("form[phx-submit=confirm_totp]", %{"totp" => %{"code" => code}})
        |> render_submit()

      assert html =~ "Save your recovery codes"
      assert html =~ "will not be shown again"
      assert TwoFactor.enabled?(Accounts.get_user(user.id))

      # Dismissed, they are gone from the page — they are stored hashed and
      # cannot be produced again.
      dismissed = lv |> element("button[phx-click=dismiss_recovery_codes]") |> render_click()
      refute dismissed =~ "Save your recovery codes"
    end

    test "once on, it can be turned off again", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings?tab=two_factor")
      lv |> element("button[phx-click=start_totp_enrolment]") |> render_click()
      code = NimbleTOTP.verification_code(Accounts.get_user(user.id).totp_secret)

      lv
      |> form("form[phx-submit=confirm_totp]", %{"totp" => %{"code" => code}})
      |> render_submit()

      lv |> element("button[phx-click=disable_totp]") |> render_click()

      refute TwoFactor.enabled?(Accounts.get_user(user.id))
    end

    test "enrolling needs a recent sign-in", %{conn: _conn} do
      user = user_fixture()

      conn =
        log_in_user(build_conn(), user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )

      {:ok, lv, _html} = live(conn, ~p"/users/settings?tab=two_factor")

      html = lv |> element("button[phx-click=start_totp_enrolment]") |> render_click()

      assert html =~ "sign in again"
      refute TwoFactor.pending?(Accounts.get_user(user.id))
    end

    test "an unknown tab falls back to Profile", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings?tab=nonsense")

      assert html =~ "Profile Information"
    end

    test "the picture upload is labelled as needing storage", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings")

      assert html =~ "needs file storage"
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Email Address"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Email Address"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings?tab=password")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings?tab=password")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Update Password"
      assert result =~ "should be at least 8 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings?tab=password")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Update Password"
      assert result =~ "should be at least 8 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
