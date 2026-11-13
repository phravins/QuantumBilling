defmodule QuantumBillingWeb.Plugs.EnforceSecurityPolicies do
  @moduledoc """
  Applies the installation's security policy to browser requests:

    * the IP allowlist, using `ClientIP` (so `x-forwarded-for` can't spoof it)
    * the inactivity timeout, also checked on LiveView mount in `UserAuth`
    * mandatory 2FA, only when an owner turns on "Enforce 2FA for everyone"
      under Settings > Security; otherwise two-factor is optional

  Settings come from `installation_settings`, not from any one business.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias QuantumBilling.InstallationSettings
  alias QuantumBillingWeb.ClientIP

  @default_timeout_minutes 60

  def init(opts), do: opts

  def call(conn, _opts) do
    organization = InstallationSettings.get()

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

  defp check_mandatory_2fa(conn, organization) do
    user = current_user(conn)

    cond do
      is_nil(user) ->
        conn

      enrolled?(user) ->
        conn

      # Pages needed to comply or sign out.
      exempt_path?(conn.request_path) ->
        conn

      not required?(organization) ->
        conn

      true ->
        conn
        |> fetch_flash()
        |> put_flash(
          :error,
          "Two-factor authentication is required on this installation. " <>
            "Set it up in your account settings to continue."
        )
        |> redirect(to: "/users/settings")
        |> halt()
    end
  end

  # Optional unless the installation enforces it.
  defp required?(%{enforce_2fa: true}), do: true
  defp required?(_organization), do: false

  # Only confirmed 2FA counts; starting enrolment stores a secret before any code is checked.
  defp enrolled?(user), do: QuantumBilling.Accounts.TwoFactor.enabled?(user)

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
