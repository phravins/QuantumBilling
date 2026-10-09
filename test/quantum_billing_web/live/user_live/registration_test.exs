defmodule QuantumBillingWeb.UserLive.RegistrationTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts

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

    test "refuses to invite an address that already has an account" do
      user = user_fixture(%{email: "test@email.com"})

      # The duplicate-email case is now caught before an invitation is ever
      # issued, which is a better place to catch it than the sign-up form.
      assert {:error, :already_registered} =
               Accounts.invite(user.email, "staff", owner_fixture(), & &1)
    end

    test "renders errors for duplicated email", %{conn: conn} do
      # An invitation issued, and the address registered by some other route
      # before the invitation was used. The unique index is the backstop.
      token = invitation_token_fixture("test@email.com")
      _existing = user_fixture(%{email: "test@email.com"})

      {:ok, lv, _html} = live(conn, ~p"/users/register?#{[token: token]}")

      result =
        lv
        |> form("#registration_form",
          user: valid_registration_attributes(email: "test@email.com")
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "renders errors for duplicated username", %{conn: conn} do
      # `registered_user_fixture/0` takes the first-account slot, so the
      # second sign-up needs an invitation like any other.
      user = registered_user_fixture()
      token = invitation_token_fixture("invited@email.com")

      {:ok, lv, _html} = live(conn, ~p"/users/register?#{[token: token]}")

      result =
        lv
        |> form("#registration_form",
          user:
            valid_registration_attributes(
              username: user.username,
              email: "invited@email.com"
            )
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "is closed without an invitation once an account exists", %{conn: conn} do
      _first = registered_user_fixture()

      {:ok, _lv, html} = live(conn, ~p"/users/register")

      # Every account here shares one set of books, so they are handed out
      # rather than claimed.
      assert html =~ "Registration is by invitation"
      refute html =~ "registration_form"
    end

    test "an invitation works once", %{conn: conn} do
      _first = registered_user_fixture()
      token = invitation_token_fixture("invited@email.com")

      {:ok, lv, _html} = live(conn, ~p"/users/register?#{[token: token]}")

      lv
      |> form("#registration_form",
        user: valid_registration_attributes(email: "invited@email.com")
      )
      |> render_submit()

      assert Accounts.get_user_by_email("invited@email.com")

      # Spent. A forwarded invitation link is not a second account.
      {:ok, _lv, html} = live(conn, ~p"/users/register?#{[token: token]}")
      assert html =~ "Registration is by invitation"
    end

    test "the first account owns the installation, invited ones do not", %{conn: conn} do
      first = registered_user_fixture()
      assert first.role == "owner"

      token = invitation_token_fixture("invited@email.com")
      {:ok, lv, _html} = live(conn, ~p"/users/register?#{[token: token]}")

      lv
      |> form("#registration_form",
        user: valid_registration_attributes(email: "invited@email.com")
      )
      |> render_submit()

      assert Accounts.get_user_by_email("invited@email.com").role == "staff"
    end

    test "an invitation registers the address it was sent to, not another", %{conn: conn} do
      _first = registered_user_fixture()
      token = invitation_token_fixture("invited@email.com")

      {:ok, lv, _html} = live(conn, ~p"/users/register?#{[token: token]}")

      # The form posts a different address — readonly is a courtesy in the
      # browser, not a control, so the server decides.
      lv
      |> form("#registration_form",
        user: valid_registration_attributes(email: "somebody-else@email.com")
      )
      |> render_submit()

      refute Accounts.get_user_by_email("somebody-else@email.com")
      assert Accounts.get_user_by_email("invited@email.com")
    end

    test "still creates the account when the relay is half-configured", %{conn: conn} do
      # A host and a username with no password: gen_smtp answers
      # `no_credentials` to this, and matching `{:ok, _}` on the confirmation
      # mail used to bring the LiveView down *after* the account was inserted,
      # leaving an account that could never confirm itself.
      #
      # Written past the changeset on purpose. The settings form rejects this
      # pairing now, so the only way to hold it is the way real databases do —
      # a row saved before that validation existed.
      # `ensure_organization/0` rather than `get_organization/0`: the latter
      # hands back an unsaved struct when the table is empty, and there is
      # nothing to write past. The settings row is a singleton, so the whole
      # table is the one row.
      QuantumBilling.Settings.ensure_organization()

      QuantumBilling.Repo.update_all(QuantumBilling.Settings.Organization,
        set: [smtp_host: "smtp.example.com", smtp_username: "postmaster", smtp_password: nil]
      )

      {:ok, lv, _html} = live(conn, ~p"/users/register")
      attrs = valid_registration_attributes()

      {:ok, _lv, html} =
        lv
        |> form("#registration_form", user: attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Account created"
      assert QuantumBilling.Accounts.get_user_by_email(attrs.email)
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
