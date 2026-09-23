defmodule QuantumBillingWeb.UserLive.ResetPasswordTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts

  # The reset link is the only place the token appears, so it is captured from
  # the URL builder rather than parsed back out of the mail body.
  defp request_reset(email) do
    parent = self()

    :ok =
      Accounts.deliver_user_reset_password_instructions(email, fn token ->
        send(parent, {:reset_token, token})
        "http://localhost/users/reset-password/#{token}"
      end)

    receive do
      {:reset_token, token} -> token
    after
      0 -> nil
    end
  end

  describe "Forgot password page" do
    test "renders the request form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/forgot-password")

      assert html =~ "Forgot your password?"
    end

    test "is reachable from the login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Forgot password?"
      assert html =~ "/users/forgot-password"
    end

    test "sends a link for a known address", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/forgot-password")

      {:ok, _lv, html} =
        lv
        |> form("#forgot_password_form", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "on its way"

      assert QuantumBilling.Repo.get_by!(Accounts.UserToken, user_id: user.id).context ==
               "reset_password"
    end

    test "answers an unknown address identically, and issues no token", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/forgot-password")

      {:ok, _lv, html} =
        lv
        |> form("#forgot_password_form", user: %{email: "nobody@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      # Identical wording is the point: the form must not reveal which
      # addresses hold accounts.
      assert html =~ "on its way"
      assert QuantumBilling.Repo.all(Accounts.UserToken) == []
    end
  end

  describe "Reset password page" do
    setup do
      user = user_fixture()
      %{user: user, token: request_reset(user.email)}
    end

    test "renders the form for a valid token", %{conn: conn, token: token, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/reset-password/#{token}")

      assert html =~ "Set a new password"
      assert html =~ user.email
    end

    test "redirects when the token is unknown", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: path}}} =
               live(conn, ~p"/users/reset-password/nonsense")

      assert path == ~p"/users/forgot-password"
    end

    test "redirects when the token has expired", %{conn: conn, token: token} do
      # Older than the four-hour window.
      QuantumBilling.Repo.update_all(Accounts.UserToken,
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -5, :hour)]
      )

      assert {:error, {:live_redirect, %{to: path}}} =
               live(conn, ~p"/users/reset-password/#{token}")

      assert path == ~p"/users/forgot-password"
    end

    test "sets a new password and invalidates the link", %{conn: conn, token: token, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      {:ok, _lv, html} =
        lv
        |> form("#reset_password_form",
          user: %{password: "a brand new password", password_confirmation: "a brand new password"}
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Password updated"

      assert Accounts.get_user_by_email_and_password(user.email, "a brand new password")
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())

      # Single use, and every other session is signed out with it.
      assert Accounts.get_user_by_reset_password_token(token) == nil
      assert QuantumBilling.Repo.all(Accounts.UserToken) == []
    end

    test "reports an invalid password rather than saving it", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      result =
        lv
        |> form("#reset_password_form",
          user: %{password: "short", password_confirmation: "mismatch"}
        )
        |> render_submit()

      assert result =~ "should be at least 8 character"
      assert result =~ "does not match password"
    end
  end

  describe "unconfirmed accounts" do
    test "resetting the password confirms the account", %{conn: conn} do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at

      token = request_reset(user.email)
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      {:ok, _lv, _html} =
        lv
        |> form("#reset_password_form",
          user: %{password: "a brand new password", password_confirmation: "a brand new password"}
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      # Following a link sent to the address proves it as well as the
      # confirmation link would, so the account is no longer locked out.
      assert QuantumBilling.Repo.reload!(user).confirmed_at
    end
  end
end
