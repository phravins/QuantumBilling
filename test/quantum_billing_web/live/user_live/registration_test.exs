defmodule QuantumBillingWeb.UserLive.RegistrationTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Create an account"
      assert html =~ "Login"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Create an account"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "creates an unconfirmed account and emails the confirmation link", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      {:ok, _lv, html} =
        lv
        |> form("#registration_form", user: valid_registration_attributes(email: email))
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "We sent a confirmation link to #{email}"

      user = QuantumBilling.Accounts.get_user_by_email_and_password(email, valid_user_password())
      assert is_nil(user.confirmed_at)

      assert QuantumBilling.Repo.get_by!(QuantumBilling.Accounts.UserToken, user_id: user.id).context ==
               "confirm"
    end

    test "renders errors when the password confirmation does not match", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form",
          user: valid_registration_attributes(password_confirmation: "something else entirely")
        )
        |> render_submit()

      assert result =~ "does not match password"
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form", user: valid_registration_attributes(email: user.email))
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "renders errors for duplicated username", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = registered_user_fixture()

      result =
        lv
        |> form("#registration_form",
          user: valid_registration_attributes(username: user.username)
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("a", "Login")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Welcome back"
    end
  end
end
