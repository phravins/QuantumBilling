defmodule QuantumBillingWeb.TwoFactorLoginTest do
  @moduledoc """
  The sign-in path with 2FA switched on.

  These are the tests that matter most in this feature: each one describes a
  way somebody could get in without the second factor.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.TwoFactor
  alias QuantumBilling.Repo

  defp enrol(user) do
    {:ok, user} = TwoFactor.start_enrolment(user)
    {:ok, user, codes} = TwoFactor.confirm_enrolment(user, code_for(user))
    # Clear the replay marker so a test can use a code straight afterwards.
    {:ok, user} = user |> Ecto.Changeset.change(%{totp_last_used_at: nil}) |> Repo.update()
    {user, codes}
  end

  defp code_for(user), do: NimbleTOTP.verification_code(user.totp_secret)

  defp sign_in_with_password(conn, user) do
    post(conn, ~p"/users/log-in", %{
      "user" => %{"email" => user.email, "password" => valid_user_password()}
    })
  end

  describe "with 2FA off" do
    test "signing in still works exactly as before", %{conn: conn} do
      user = user_fixture() |> set_password()

      conn = sign_in_with_password(conn, user)

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "password sign-in with 2FA on" do
    setup do
      {user, codes} = enrol(user_fixture() |> set_password())
      %{user: user, recovery_codes: codes}
    end

    test "the correct password alone does NOT sign you in", %{conn: conn, user: user} do
      conn = sign_in_with_password(conn, user)

      # The whole point: no session token is issued at this stage.
      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/two-factor"
    end

    test "the pending marker is not itself a credential", %{conn: conn, user: user} do
      conn = sign_in_with_password(conn, user)

      # Carrying the half-finished sign-in to a protected page must not work.
      conn = get(recycle(conn), ~p"/dashboard")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "a wrong password still fails before any challenge", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "wrong password"}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "a valid code completes the sign-in", %{conn: conn, user: user} do
      conn = sign_in_with_password(conn, user)

      conn = post(recycle(conn), ~p"/users/two-factor", %{"user" => %{"code" => code_for(user)}})

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "a wrong code does not", %{conn: conn, user: user} do
      conn = sign_in_with_password(conn, user)

      conn = post(recycle(conn), ~p"/users/two-factor", %{"user" => %{"code" => "000000"}})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/two-factor"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not valid"
    end

    test "repeated invalid codes trigger rate limiting", %{conn: conn, user: user} do
      conn = sign_in_with_password(conn, user)

      # 5 attempts permitted within the window; 6th is rate limited
      conn =
        Enum.reduce(1..5, conn, fn _, c ->
          post(recycle(c), ~p"/users/two-factor", %{"user" => %{"code" => "000000"}})
        end)

      blocked = post(recycle(conn), ~p"/users/two-factor", %{"user" => %{"code" => "000000"}})
      assert Phoenix.Flash.get(blocked.assigns.flash, :error) =~ "Too many invalid 2FA attempts"
    end

    test "a recovery code completes it, and only once", %{
      conn: conn,
      user: user,
      recovery_codes: [code | _]
    } do
      conn = sign_in_with_password(conn, user)
      conn = post(recycle(conn), ~p"/users/two-factor", %{"user" => %{"code" => code}})

      assert get_session(conn, :user_token)

      # The same code must not open the door a second time.
      second = sign_in_with_password(build_conn(), user)
      second = post(recycle(second), ~p"/users/two-factor", %{"user" => %{"code" => code}})

      refute get_session(second, :user_token)
    end

    test "the challenge cannot be reached without passing the password step", %{conn: conn} do
      conn = post(conn, ~p"/users/two-factor", %{"user" => %{"code" => "123456"}})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "the challenge page redirects when nothing is pending", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/two-factor")
    end

    test "the challenge page renders for a pending sign-in", %{conn: conn, user: user} do
      conn = sign_in_with_password(conn, user)

      {:ok, _view, html} = live(recycle(conn), ~p"/users/two-factor")

      assert html =~ "Two-factor authentication"
      assert html =~ "6-digit code"
      assert html =~ "recovery code"
    end

    test "remember me survives the challenge", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      conn = post(recycle(conn), ~p"/users/two-factor", %{"user" => %{"code" => code_for(user)}})

      assert conn.resp_cookies["_quantum_billing_web_user_remember_me"]
    end
  end

  describe "the magic link door" do
    setup do
      {user, _codes} = enrol(user_fixture() |> set_password())
      %{user: user}
    end

    test "is challenged too", %{conn: conn, user: user} do
      # Without this, anyone holding the inbox bypasses 2FA entirely.
      {encoded, _hashed} = generate_user_magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => encoded}})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/two-factor"
    end

    test "completes once the code is given", %{conn: conn, user: user} do
      {encoded, _hashed} = generate_user_magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => encoded}})
      conn = post(recycle(conn), ~p"/users/two-factor", %{"user" => %{"code" => code_for(user)}})

      assert get_session(conn, :user_token)
    end
  end

  describe "expiry" do
    test "a stale pending sign-in is refused", %{conn: conn} do
      {user, _codes} = enrol(user_fixture() |> set_password())

      conn = sign_in_with_password(conn, user)

      # Wind the attempt back past the ten-minute window.
      stale =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          pending_two_factor: %{
            "user_id" => user.id,
            "at" => System.system_time(:second) - 601,
            "remember_me" => false,
            "return_to" => nil
          }
        })

      conn = post(stale, ~p"/users/two-factor", %{"user" => %{"code" => code_for(user)}})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end
  end

  describe "enrolling does not lock anyone out" do
    test "a started but unconfirmed enrolment does not challenge sign-in", %{conn: conn} do
      user = user_fixture() |> set_password()
      {:ok, _user} = TwoFactor.start_enrolment(user)

      conn = sign_in_with_password(conn, Accounts.get_user(user.id))

      # Someone who opened the setup screen and walked away must still be able
      # to sign in normally.
      assert get_session(conn, :user_token)
    end
  end
end
