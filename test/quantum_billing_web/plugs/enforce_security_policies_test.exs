defmodule QuantumBillingWeb.Plugs.EnforceSecurityPoliciesTest do
  use QuantumBillingWeb.ConnCase, async: false

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Settings
  alias QuantumBillingWeb.Plugs.EnforceSecurityPolicies

  setup do
    org = Settings.ensure_organization()

    on_exit(fn ->
      Settings.update_section(
        org,
        %{
          allowed_ips: nil,
          session_timeout_minutes: 60,
          enforce_2fa: false
        },
        :security
      )
    end)

    {:ok, org: org}
  end

  describe "IP Whitelisting" do
    test "allows access when allowed_ips is nil or empty", %{conn: conn, org: org} do
      Settings.update_section(org, %{allowed_ips: nil}, :security)
      conn = EnforceSecurityPolicies.call(conn, [])
      refute conn.halted
    end

    test "allows matching client IP", %{conn: conn, org: org} do
      Settings.update_section(org, %{allowed_ips: "127.0.0.1, 192.168.1.1"}, :security)
      conn = %{conn | remote_ip: {127, 0, 0, 1}} |> EnforceSecurityPolicies.call([])
      refute conn.halted
    end

    test "blocks unlisted client IP with 403 Forbidden", %{conn: conn, org: org} do
      Settings.update_section(org, %{allowed_ips: "10.0.0.5"}, :security)
      conn = %{conn | remote_ip: {192, 168, 1, 99}} |> EnforceSecurityPolicies.call([])
      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body =~ "Access Denied: Your IP address"
    end
  end

  describe "Session Timeout" do
    test "allows active session within timeout window", %{conn: conn, org: _org} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> QuantumBillingWeb.UserAuth.fetch_current_scope_for_user([])
        |> fetch_session()
        |> put_session(:last_activity_at, System.system_time(:second) - 60)
        |> EnforceSecurityPolicies.call([])

      refute conn.halted
    end

    test "logs out user when session exceeds timeout", %{conn: conn, org: org} do
      Settings.update_section(org, %{session_timeout_minutes: 5}, :security)
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> QuantumBillingWeb.UserAuth.fetch_current_scope_for_user([])
        |> fetch_session()
        |> put_session(:last_activity_at, System.system_time(:second) - 600)
        |> EnforceSecurityPolicies.call([])

      assert conn.halted
      assert redirected_to(conn) == "/users/log-in"
    end
  end
end
