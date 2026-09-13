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

    test "allows an address inside an allowed CIDR block", %{conn: conn, org: org} do
      Settings.update_section(org, %{allowed_ips: "10.0.0.0/8, 192.168.1.0/24"}, :security)

      conn = %{conn | remote_ip: {10, 4, 5, 6}} |> EnforceSecurityPolicies.call([])

      refute conn.halted
    end

    test "does not believe x-forwarded-for from an undeclared proxy", %{conn: conn, org: org} do
      Settings.update_section(org, %{allowed_ips: "127.0.0.1"}, :security)

      # Anyone can send this header. If the allowlist honoured it, the
      # allowlist would admit everyone.
      conn =
        %{conn | remote_ip: {203, 0, 113, 7}}
        |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1")
        |> EnforceSecurityPolicies.call([])

      assert conn.halted
      assert conn.status == 403
    end

    test "believes it when the connection comes from a declared proxy", %{conn: conn, org: org} do
      Settings.update_section(org, %{allowed_ips: "198.51.100.4"}, :security)
      previous = Application.get_env(:quantum_billing, :trusted_proxies, [])
      Application.put_env(:quantum_billing, :trusted_proxies, ["10.0.0.0/8"])
      on_exit(fn -> Application.put_env(:quantum_billing, :trusted_proxies, previous) end)

      conn =
        %{conn | remote_ip: {10, 0, 0, 5}}
        |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.4")
        |> EnforceSecurityPolicies.call([])

      refute conn.halted
    end

    test "a malformed allowlist entry does not admit everybody", %{conn: conn, org: org} do
      Settings.update_section(org, %{allowed_ips: "10.0.0.5"}, :security)
      # Written straight to the column, as an older row or a console edit could
      # leave it — the changeset now rejects this on the way in.
      QuantumBilling.Repo.update_all(QuantumBilling.Settings.Organization,
        set: [allowed_ips: "not-an-ip"]
      )

      conn = %{conn | remote_ip: {10, 0, 0, 5}} |> EnforceSecurityPolicies.call([])

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "the allowlist setting" do
    test "rejects entries that are not addresses or blocks", %{org: org} do
      assert {:error, changeset} =
               Settings.update_section(org, %{allowed_ips: "10.0.0.1, nonsense"}, :security)

      assert [allowed_ips: {message, _opts}] = changeset.errors
      assert message =~ "nonsense"
    end

    test "accepts addresses and CIDR blocks in both IP versions", %{org: org} do
      assert {:ok, _organization} =
               Settings.update_section(
                 org,
                 %{allowed_ips: "127.0.0.1, 10.0.0.0/8, ::1, 2001:db8::/32"},
                 :security
               )
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
