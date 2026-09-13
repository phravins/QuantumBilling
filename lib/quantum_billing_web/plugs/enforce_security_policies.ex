defmodule QuantumBillingWeb.Plugs.EnforceSecurityPolicies do
  @moduledoc """
  Applies the organisation's own security policy to every browser request:

    * the IP allowlist, if one is set;
    * the inactivity timeout on a signed-in session;
    * mandatory two-factor enrolment, if the organisation requires it.

  All three read from `organization_settings`, so they are policy the business
  sets rather than constants in the code.

  Two details matter more than they look:

  **Where the client's address comes from.** `QuantumBillingWeb.ClientIP`
  decides, and it ignores `x-forwarded-for` unless the connection arrives from
  a declared proxy. An allowlist that believes that header is not an allowlist
  — the header is written by whoever sends the request.

  **What the timeout measures.** The clock advances on requests that reach this
  plug — page loads and form posts — and is *checked* again whenever a
  LiveView mounts, in `QuantumBillingWeb.UserAuth.on_mount/4`. A LiveView
  cannot write to the session cookie, so time spent inside one does not push
  the window forward; what the mount check buys is that a tab left open for
  days is signed out when it reconnects, instead of waiting for the next full
  page load to notice.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias QuantumBilling.Settings
  alias QuantumBillingWeb.ClientIP

  @default_timeout_minutes 60

  def init(opts), do: opts

  def call(conn, _opts) do
    organization = Settings.get_organization()

    conn
    |> check_ip_allowlist(organization)
    |> check_session_timeout(organization)
    |> check_mandatory_2fa(organization)
  end

  defp check_ip_allowlist(%{halted: true} = conn, _organization), do: conn

  defp check_ip_allowlist(conn, organization) do
    case allowed_entries(organization) do
      [] ->
        conn

      entries ->
        client_ip = ClientIP.client_ip_tuple(conn)

        if ClientIP.allowed?(client_ip, entries) do
          conn
        else
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(
            403,
            "Access Denied: Your IP address (#{ClientIP.to_string_ip(client_ip)}) is not " <>
              "permitted by organization security policies."
          )
          |> halt()
        end
    end
  end

  defp allowed_entries(%{allowed_ips: list}) when is_binary(list) do
    list
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp allowed_entries(_organization), do: []

  defp check_session_timeout(%{halted: true} = conn, _organization), do: conn

  defp check_session_timeout(conn, organization) do
    if current_user(conn) do
      timeout_seconds = timeout_minutes(organization) * 60
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

  defp timeout_minutes(%{session_timeout_minutes: minutes})
       when is_integer(minutes) and minutes > 0,
       do: minutes

  defp timeout_minutes(_organization), do: @default_timeout_minutes

  defp check_mandatory_2fa(%{halted: true} = conn, _organization), do: conn

  defp check_mandatory_2fa(conn, %{enforce_2fa: true} = _organization) do
    user = current_user(conn)

    cond do
      is_nil(user) ->
        conn

      enrolled?(user) ->
        conn

      # The places a user has to be able to reach in order to comply, or to
      # leave. Without these the policy locks everybody out of the page that
      # would let them satisfy it.
      exempt_path?(conn.request_path) ->
        conn

      true ->
        conn
        |> fetch_flash()
        |> put_flash(
          :error,
          "Your organization requires Two-Factor Authentication (2FA). " <>
            "Please configure 2FA in your account settings."
        )
        |> redirect(to: "/users/settings")
        |> halt()
    end
  end

  defp check_mandatory_2fa(conn, _organization), do: conn

  defp enrolled?(%{totp_secret: secret}), do: is_binary(secret) and secret != ""
  defp enrolled?(_user), do: false

  defp exempt_path?(path) do
    String.starts_with?(path, "/users/settings") or
      String.starts_with?(path, "/users/log-out") or
      String.starts_with?(path, "/users/two-factor")
  end

  defp current_user(conn) do
    case conn.assigns do
      %{current_scope: %{user: %QuantumBilling.Accounts.User{} = user}} -> user
      _no_user -> nil
    end
  end
end
