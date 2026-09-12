defmodule QuantumBillingWeb.Plugs.EnforceSecurityPolicies do
  @moduledoc """
  Plug to enforce organization security policies:
  - IP Whitelisting (IPv4/IPv6 CIDRs and single IPs)
  - Inactivity Session Timeout
  - Mandatory Two-Factor Authentication (2FA) enforcement
  """

  import Plug.Conn
  import Phoenix.Controller
  import Bitwise

  alias QuantumBilling.Settings

  def init(opts), do: opts

  def call(conn, _opts) do
    org = Settings.get_organization()

    conn
    |> check_ip_whitelisting(org)
    |> check_session_timeout(org)
    |> check_mandatory_2fa(org)
  end

  defp check_ip_whitelisting(%{halted: true} = conn, _org), do: conn

  defp check_ip_whitelisting(conn, org) do
    if org && org.allowed_ips && String.trim(org.allowed_ips) != "" do
      client_ip_str = get_client_ip_str(conn)
      allowed_list = String.split(org.allowed_ips, ",", trim: true) |> Enum.map(&String.trim/1)

      if ip_allowed?(client_ip_str, allowed_list) do
        conn
      else
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          403,
          "Access Denied: Your IP address (#{client_ip_str}) is not permitted by organization security policies."
        )
        |> halt()
      end
    else
      conn
    end
  end

  defp check_session_timeout(%{halted: true} = conn, _org), do: conn

  defp check_session_timeout(conn, org) do
    user = get_current_user(conn)

    if user do
      conn = fetch_session(conn)
      timeout_minutes = (org && org.session_timeout_minutes) || 60
      timeout_seconds = timeout_minutes * 60
      now = System.system_time(:second)
      last_activity = get_session(conn, :last_activity_at)

      if last_activity && now - last_activity > timeout_seconds do
        conn
        |> fetch_flash()
        |> put_flash(:error, "Your session has expired due to inactivity. Please log in again.")
        |> QuantumBillingWeb.UserAuth.log_out_user()
        |> halt()
      else
        put_session(conn, :last_activity_at, now)
      end
    else
      conn
    end
  end

  defp check_mandatory_2fa(%{halted: true} = conn, _org), do: conn

  defp check_mandatory_2fa(conn, org) do
    user = get_current_user(conn)
    path = conn.request_path

    if user && org && org.enforce_2fa == true do
      has_2fa = is_binary(user.totp_secret) && user.totp_secret != ""

      exempt_path? =
        String.starts_with?(path, "/users/settings") or
          String.starts_with?(path, "/users/log-out")

      if not has_2fa and not exempt_path? do
        conn
        |> fetch_flash()
        |> put_flash(
          :error,
          "Your organization requires Two-Factor Authentication (2FA). Please configure 2FA in your account settings."
        )
        |> redirect(to: "/users/settings")
        |> halt()
      else
        conn
      end
    else
      conn
    end
  end

  defp get_current_user(conn) do
    case conn.assigns do
      %{current_scope: %{user: %QuantumBilling.Accounts.User{} = user}} -> user
      _ -> nil
    end
  end

  defp get_client_ip_str(conn) do
    forwarded_for = get_req_header(conn, "x-forwarded-for")

    ip_tuple =
      case forwarded_for do
        [first | _] ->
          first
          |> String.split(",")
          |> List.first()
          |> String.trim()
          |> parse_ip()

        _ ->
          conn.remote_ip
      end

    format_ip(ip_tuple)
  end

  defp parse_ip(str) do
    case :inet.parse_address(to_charlist(str)) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}),
    do: :inet.ntoa({a, b, c, d, e, f, g, h}) |> to_string()

  defp format_ip(_), do: "127.0.0.1"

  defp ip_allowed?(client_ip, allowed_list) do
    Enum.any?(allowed_list, fn entry ->
      cond do
        entry == client_ip ->
          true

        entry in ["127.0.0.1", "::1", "localhost"] and
            client_ip in ["127.0.0.1", "::1", "localhost"] ->
          true

        String.contains?(entry, "/") ->
          cidr_contains?(entry, client_ip)

        true ->
          false
      end
    end)
  end

  defp cidr_contains?(cidr, client_ip) do
    case String.split(cidr, "/") do
      [network, prefix_len_str] ->
        with {:ok, net_ip} <- :inet.parse_address(to_charlist(network)),
             {:ok, host_ip} <- :inet.parse_address(to_charlist(client_ip)),
             {prefix_len, ""} <- Integer.parse(prefix_len_str) do
          match_ip_prefix(net_ip, host_ip, prefix_len)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp match_ip_prefix({a1, a2, a3, a4}, {b1, b2, b3, b4}, prefix_len)
       when prefix_len >= 0 and prefix_len <= 32 do
    mask = Bitwise.bsl(0xFFFFFFFF, 32 - prefix_len) &&& 0xFFFFFFFF
    ip1 = Bitwise.bsl(a1, 24) + Bitwise.bsl(a2, 16) + Bitwise.bsl(a3, 8) + a4
    ip2 = Bitwise.bsl(b1, 24) + Bitwise.bsl(b2, 16) + Bitwise.bsl(b3, 8) + b4
    (ip1 &&& mask) == (ip2 &&& mask)
  end

  defp match_ip_prefix(_, _, _), do: false
end
