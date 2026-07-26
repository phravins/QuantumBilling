defmodule QuantumBillingWeb.UserConfirmationControllerTest do
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts
  alias QuantumBilling.Repo

  setup do
    user = registered_user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_confirmation_instructions(user, url)
      end)

    %{user: user, token: token}
  end

  describe "GET /users/confirm/:token" do
    test "confirms the account and sends the user to log in", %{
      conn: conn,
      user: user,
      token: token
    } do
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account confirmed"
      assert Repo.get!(Accounts.User, user.id).confirmed_at
    end

    test "does not log the user in", %{conn: conn, token: token} do
      conn = get(conn, ~p"/users/confirm/#{token}")

      refute get_session(conn, :user_token)
    end

    test "flashes an error for an invalid token", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/confirm/oops")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or it has expired"
      refute Repo.get!(Accounts.User, user.id).confirmed_at
    end
  end
end
