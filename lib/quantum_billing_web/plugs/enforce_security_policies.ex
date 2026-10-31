defmodule QuantumBillingWeb.Plugs.EnforceSecurityPolicies do
  @moduledoc """
  Applies the installation's security policy to every browser request:

    * the IP allowlist, if one is set;
    * the inactivity timeout on a signed-in session;
    * mandatory two-factor enrolment — for everyone when the installation
      requires it, and always for anyone who owns a business: an owner can
      hand out accounts, issue API keys and export everything, so their
      password alone must not be enough. (`:require_owner_2fa`, on unless
      configured off.)

  All three read from `installation_settings`, so they are policy the owners
  set rather than constants in the code. They belong to the installation, not to
  any one business: they guard the sign-in page, which is reached before a
  business is chosen, and one person works across several firms with one login.

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

      not required?(organization, user) ->
        conn

      true ->
        conn
        |> fetch_flash()
        |> put_flash(
          :error,
          "Two-factor authentication is required for your account. " <>
            "Set it up in your account settings to continue."
        )
        |> redirect(to: "/users/settings")
        |> halt()
    end
  end

  # Asked only of someone not enrolled, so the query is not on every request.
  defp required?(%{enforce_2fa: true}, _user), do: true

  defp required?(_organization, user) do
    Application.get_env(:quantum_billing, :require_owner_2fa, true) and
      QuantumBilling.Businesses.owns_any?(user)
  end

  # Confirmed, not merely started: opening the enrolment screen stores a secret
  # before any code has been checked, and counting that would let anyone meet
  # the requirement by starting enrolment and walking away.
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
