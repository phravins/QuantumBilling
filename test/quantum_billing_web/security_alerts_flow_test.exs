defmodule QuantumBillingWeb.SecurityAlertsFlowTest do
  @moduledoc "The alerts, raised from where they happen."
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures
  import Swoosh.TestAssertions

  # Account fixtures send their own confirmation mail; drop it so the
  # assertions below see only alerts.
  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp sign_in(conn, email, password) do
    post(conn, ~p"/users/log-in", %{"user" => %{"email" => email, "password" => password}})
  end

  test "the fifth wrong password locks sign-in and emails the account holder" do
    user = user_fixture() |> set_password()
    flush_emails()

    for _ <- 1..4, do: sign_in(build_conn(), user.email, "wrong password")
    refute_email_sent()

    sign_in(build_conn(), user.email, "wrong password")

    assert_email_sent(fn email ->
      assert email.to == [{"", user.email}]
      assert email.subject =~ "Failed sign-in attempts"
    end)
  end

  describe "behind a trusted proxy" do
    setup do
      previous = Application.get_env(:quantum_billing, :trusted_proxies)
      Application.put_env(:quantum_billing, :trusted_proxies, ["127.0.0.1"])
      on_exit(fn -> Application.put_env(:quantum_billing, :trusted_proxies, previous || []) end)
    end

    test "the per-address sign-in limit counts each client, not the proxy" do
      victim = user_fixture() |> set_password()

      # Ten bad passwords from one client behind the proxy...
      for n <- 1..10 do
        build_conn()
        |> put_req_header("x-forwarded-for", "198.51.100.66")
        |> sign_in("nobody#{n}@example.com", "wrong")
      end

      # ...do not lock out a different client behind the same proxy.
      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "203.0.113.20")
        |> sign_in(victim.email, valid_user_password())

      assert get_session(conn, :user_token)
    end
  end

  test "downloading a full backup tells the owners" do
    owner = owner_fixture()
    flush_emails()

    log_in_user(build_conn(), owner) |> get(~p"/settings/backup/download")

    assert_email_sent(fn email -> assert email.subject =~ "downloaded a full backup" end)
  end

  test "an owner creating an API key tells the owners" do
    owner = owner_fixture()
    flush_emails()
    {:ok, view, _html} = live(log_in_user(build_conn(), owner), ~p"/settings/api-keys")

    view
    |> form("#api-key-form", %{
      "api_key" => %{"name" => "ERP", "expires_in" => "90", "scopes" => ["invoices:read"]}
    })
    |> render_submit()

    assert_email_sent(fn email -> assert email.subject =~ "created the API key \"ERP\"" end)
  end
end
