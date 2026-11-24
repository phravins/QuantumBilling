defmodule QuantumBillingWeb.UserAuth do
  use QuantumBillingWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  require Logger

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit
  alias QuantumBilling.Businesses
  alias QuantumBilling.Events
  alias QuantumBilling.InstallationSettings
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.RateLimiter
  alias QuantumBillingWeb.ClientIP

  @owner_only_message "That area is limited to account owners."

  # Should match the session validity in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_quantum_billing_web_user_remember_me"
  # Secure in production, encrypted and HttpOnly.
  @remember_me_options [
    encrypt: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax",
    secure: Application.compile_env(:quantum_billing, :secure_session_cookie, false)
  ]

  # Tokens older than this are reissued.
  @session_reissue_age_in_days 7

  # Names this browser, so "one device at a time" can tell its own sessions
  # (reissued tokens included) from another device's. Signed, not secret.
  @device_cookie "_quantum_billing_device"
  @device_cookie_options [
    sign: true,
    max_age: 365 * 24 * 60 * 60,
    same_site: "Lax",
    http_only: true,
    secure: Application.compile_env(:quantum_billing, :secure_session_cookie, false)
  ]

  @replaced_message "You were signed out because your account is now signed in on another device."

  @doc "Logs the user in and redirects to `:user_return_to` or `signed_in_path/1`."
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    # Records the sign-in and alerts the user if it is from somewhere new.
    QuantumBilling.SecurityAlerts.signed_in(
      user,
      conn
      |> QuantumBillingWeb.ClientIP.client_ip_tuple()
      |> QuantumBillingWeb.ClientIP.to_string_ip(),
      conn |> get_req_header("user-agent") |> List.first(),
      :browser
    )

    # Onboarding first; it leads on to "/" when done.
    to =
      if Accounts.onboarding_pending?(user),
        do: ~p"/onboarding",
        else: user_return_to || signed_in_path(conn)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: to)
  end

  @pending_two_factor_key :pending_two_factor
  @pending_two_factor_ttl_seconds 600

  @doc """
  Holds a password-verified user until they pass the second factor.

  Renews the session but does not write `:user_token`, so the visitor is
  still signed out until the code is checked.
  """
  def stash_pending_two_factor(conn, user, params) do
    conn
    |> renew_session(nil)
    |> put_session(@pending_two_factor_key, %{
      "user_id" => user.id,
      "at" => System.system_time(:second),
      "remember_me" => params["remember_me"] == "true",
      "return_to" => get_session(conn, :user_return_to)
    })
  end

  @doc "The user waiting on a second factor, or `nil` if missing or expired."
  def pending_two_factor(conn) do
    with %{"user_id" => id, "at" => at} = pending <- get_session(conn, @pending_two_factor_key),
         true <- System.system_time(:second) - at <= @pending_two_factor_ttl_seconds,
         %Accounts.User{} = user <- Accounts.get_user(id) do
      {user, pending}
    else
      _ -> nil
    end
  end

  @doc "Drops any half-finished sign-in."
  def clear_pending_two_factor(conn), do: delete_session(conn, @pending_two_factor_key)

  @doc """
  Completes a sign-in that was held for a second factor.
  """
  def complete_two_factor_login(conn, user, pending) do
    conn
    |> clear_pending_two_factor()
    |> maybe_restore_return_to(pending["return_to"])
    |> log_in_or_hold(user, %{"remember_me" => to_string(pending["remember_me"])})
  end

  @pending_sign_in_key :pending_sign_in

  @doc """
  Signs in a user whose password (and any second factor) was accepted, unless
  "One device at a time" is on and the account is in use on another device.
  Then the sign-in is held, the other device is asked to allow it, and the
  visitor waits at /users/session-conflict, still signed out.
  """
  def log_in_or_hold(conn, user, params \\ %{}) do
    {device_id, conn} = ensure_device_id(conn)
    rules = InstallationSettings.get()

    cond do
      not rules.single_session or signed_in_as?(conn, user) ->
        log_in_user(conn, user, params)

      Accounts.active_session_elsewhere?(user, device_id, activity_minutes(rules)) ->
        hold_for_other_device(conn, user, params, device_id)

      true ->
        conn = log_in_user(conn, user, params)
        # Sessions left on other devices, remember-me included, end here.
        user |> Accounts.replace_sessions(device_id) |> disconnect_sessions()
        conn
    end
  end

  # A device counts as in use while it is inside the idle timeout.
  defp activity_minutes(%{session_timeout_minutes: minutes})
       when is_integer(minutes) and minutes > 0,
       do: minutes

  defp activity_minutes(_rules), do: 60

  defp signed_in_as?(conn, user),
    do:
      match?(
        %Scope{user: %Accounts.User{id: id}} when id == user.id,
        conn.assigns[:current_scope]
      )

  defp hold_for_other_device(conn, user, params, device_id) do
    case RateLimiter.hit({:sign_in_request, user.id}, 3, 600) do
      {:ok, _remaining} ->
        {:ok, request_token} =
          Accounts.create_sign_in_request(user, %{
            device_id: device_id,
            user_agent: user_agent(conn),
            ip_address: client_ip(conn)
          })

        return_to = get_session(conn, :user_return_to)

        conn
        |> renew_session(nil)
        |> put_session(@pending_sign_in_key, %{
          "token" => request_token,
          "remember_me" => params["remember_me"] == "true",
          "return_to" => return_to
        })
        |> redirect(to: ~p"/users/session-conflict")

      {:error, :rate_limited, _retry_after} ->
        conn
        |> put_flash(:error, "Too many sign-in requests. Try again in a few minutes.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc "The sign-in held for another device's answer, or `nil`."
  def pending_sign_in(conn) do
    case get_session(conn, @pending_sign_in_key) do
      %{"token" => token} = pending when is_binary(token) -> pending
      _ -> nil
    end
  end

  @doc "Drops a held sign-in."
  def clear_pending_sign_in(conn), do: delete_session(conn, @pending_sign_in_key)

  @doc """
  Finishes a held sign-in once the other device allowed it, ending every
  other session the user still has.
  """
  def complete_held_sign_in(conn, user, pending) do
    {device_id, conn} = ensure_device_id(conn)

    conn =
      conn
      |> clear_pending_sign_in()
      |> maybe_restore_return_to(pending["return_to"])
      |> log_in_user(user, %{"remember_me" => to_string(pending["remember_me"])})

    user |> Accounts.replace_sessions(device_id) |> disconnect_sessions()
    Logger.info("[security] sign-in approved from another device user=#{user.id}")

    conn
  end

  defp ensure_device_id(conn) do
    case read_device_id(conn) do
      nil ->
        id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

        conn =
          conn
          |> put_resp_cookie(@device_cookie, id, @device_cookie_options)
          |> put_private(:device_id, id)

        {id, conn}

      id ->
        {id, conn}
    end
  end

  defp read_device_id(%Plug.Conn{private: %{device_id: id}}), do: id

  defp read_device_id(conn) do
    conn = fetch_cookies(conn, signed: [@device_cookie])

    case conn.cookies[@device_cookie] do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp user_agent(conn), do: conn |> get_req_header("user-agent") |> List.first()

  defp client_ip(conn),
    do:
      conn
      |> QuantumBillingWeb.ClientIP.client_ip_tuple()
      |> QuantumBillingWeb.ClientIP.to_string_ip()

  defp maybe_restore_return_to(conn, nil), do: conn
  defp maybe_restore_return_to(conn, path), do: put_session(conn, :user_return_to, path)

  @doc "Logs the user out and clears the session."
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    # Older tokens this browser was reissued from go too.
    with %Scope{user: %Accounts.User{} = user} <- conn.assigns[:current_scope],
         device_id when is_binary(device_id) <- read_device_id(conn) do
      user |> Accounts.delete_device_sessions(device_id) |> disconnect_sessions()
    end

    if live_socket_id = get_session(conn, :live_socket_id) do
      QuantumBillingWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    # To the sign-in page, since / would add a "must log in" flash.
    |> redirect(to: ~p"/users/log-in")
  end

  @doc "Authenticates the user from the session or remember-me cookie, reissuing old tokens."
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn) do
      case Accounts.get_user_by_session_token(token) do
        {user, token_inserted_at} ->
          conn
          |> assign(:current_scope, Scope.for_user(user))
          |> maybe_reissue_user_session_token(user, token_inserted_at)

        nil ->
          conn
          |> drop_replaced_session(token)
          |> assign(:current_scope, Scope.for_user(nil))
      end
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  # A session ended so the account could sign in elsewhere: forget it, and say why.
  defp drop_replaced_session(conn, token) do
    if Accounts.session_replaced?(token) do
      conn
      |> delete_session(:user_token)
      |> delete_session(:live_socket_id)
      |> delete_session(:user_remember_me)
      |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
      |> then(fn conn ->
        if Map.has_key?(conn.assigns, :flash),
          do: put_flash(conn, :error, @replaced_message),
          else: conn
      end)
    else
      conn
    end
  end

  @doc """
  Chooses the business this request works in and points `Repo` at its schema.

  Uses the session's `"business_id"` if still valid, or the user's only
  business. With several and no valid choice, none is chosen.
  """
  def fetch_current_business(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: %Accounts.User{} = user} = scope ->
        scope = choose_business(scope, get_session(conn, :business_id))
        Repo.put_business(scope.business)
        Audit.put_actor(user_actor(user, ClientIP.client_ip(conn)))
        scope = put_tax_regime(scope)

        conn
        |> assign(:current_scope, scope)
        |> remember_business(scope.business)

      _signed_out ->
        conn
    end
  end

  defp remember_business(conn, nil), do: conn

  defp remember_business(conn, %{id: id}) do
    if get_session(conn, :business_id) == id, do: conn, else: put_session(conn, :business_id, id)
  end

  defp choose_business(%Scope{user: user} = scope, business_id) do
    pairs = Businesses.list_for_user(user)
    scope = %{scope | businesses: Enum.map(pairs, &elem(&1, 0))}

    case Enum.find(pairs, fn {business, _} -> business.id == business_id end) || only(pairs) do
      {business, membership} -> Scope.put_membership(scope, %{membership | business: business})
      nil -> scope
    end
  end

  defp only([pair]), do: pair
  defp only(_none_or_several), do: nil

  @doc "Plug that sends a user without a chosen business to the picker."
  def require_business(conn, _opts) do
    if conn.assigns.current_scope.business do
      conn
    else
      conn
      |> redirect(to: ~p"/businesses")
      |> halt()
    end
  end

  @doc "The PubSub topic for one browser, keyed by a hash of the session token."
  def browser_topic(token) when is_binary(token) do
    "browser:" <> Base.url_encode64(:crypto.hash(:sha256, token), padding: false)
  end

  @doc "Tells this browser's other tabs to reload into `business_id`."
  def broadcast_business_switch(conn, business_id) do
    if token = get_session(conn, :user_token) do
      Events.broadcast(browser_topic(token), {:business_switched, business_id})
    end

    conn
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, encrypted: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # Called on login, in sudo mode, or to renew a session. Cleared first to prevent fixation.
  defp create_or_extend_session(conn, user, params) do
    {device_id, conn} = ensure_device_id(conn)

    token =
      Accounts.generate_user_session_token(user, %{
        device_id: device_id,
        user_agent: user_agent(conn),
        ip_address: client_ip(conn)
      })

    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # An already logged-in session is not renewed, to avoid CSRF errors in open tabs.
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      QuantumBillingWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  @doc """
  Disconnects every open LiveView `user` has, so they remount under new access.

  Sessions survive; the user stays signed in.
  """
  def disconnect_user(%Accounts.User{} = user) do
    user |> Accounts.list_user_session_tokens() |> disconnect_sessions()
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  LiveView `on_mount` hooks.

    * `:mount_current_scope` - assigns `current_scope`, or nil.
    * `:require_authenticated` - as above, redirecting to log in if signed out.
    * `:require_onboarded` - sends users who have not onboarded to /onboarding.
    * `:require_business` - sends users without a business to the picker.
    * `:require_owner` - sends staff to the dashboard.
    * `:require_admin` - answers 404 to anyone but a super admin.
    * `:check_maintenance` - sends everyone but super admins to /maintenance
      while maintenance mode is on.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    cond do
      session_expired?(session) ->
        # An idle tab makes no HTTP request, so the plug cannot expire it.
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "Your session has expired due to inactivity. Please log in again."
          )
          # Redirect: a LiveView cannot clear the cookie; EnforceSecurityPolicies signs out.
          |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

        {:halt, socket}

      socket.assigns.current_scope && socket.assigns.current_scope.user ->
        if Phoenix.LiveView.connected?(socket), do: Accounts.touch_session(session["user_token"])
        {:cont, watch_own_account(socket)}

      true ->
        message =
          if Accounts.session_replaced?(session["user_token"]),
            do: @replaced_message,
            else: "You must log in to access this page."

        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, message)
          |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

        {:halt, socket}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.user, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must re-authenticate to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_business, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{business: %{id: business_id}} ->
        {:cont, follow_business_switches(socket, session["user_token"], business_id)}

      _no_business ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/businesses")}
    end
  end

  # Only on business pages, never on /onboarding or account pages, so it cannot loop.
  def on_mount(:require_onboarded, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{user: %Accounts.User{} = user} ->
        if Accounts.onboarding_pending?(user),
          do: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/onboarding")},
          else: {:cont, socket}

      _signed_out ->
        {:cont, socket}
    end
  end

  def on_mount(:require_owner, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Scope.owner?(socket.assigns.current_scope) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, @owner_only_message)
        |> Phoenix.LiveView.redirect(to: ~p"/dashboard")

      {:halt, socket}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Scope.admin?(socket.assigns.current_scope),
      do: {:cont, socket},
      else: raise(QuantumBillingWeb.NotFoundError)
  end

  def on_mount(:check_maintenance, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if under_maintenance?(socket.assigns.current_scope),
      do: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/maintenance")},
      else: {:cont, socket}
  end

  defp under_maintenance?(scope),
    do: not Scope.admin?(scope) and InstallationSettings.maintenance?()

  # Same stamp and setting as the plug.
  defp session_expired?(session) do
    with last_activity when is_integer(last_activity) <- session["last_activity_at"],
         minutes when is_integer(minutes) and minutes > 0 <-
           InstallationSettings.get().session_timeout_minutes do
      System.system_time(:second) - last_activity > minutes * 60
    else
      _no_stamp_or_setting -> false
    end
  end

  # A switch in another tab reloads this one; only a page load re-reads the business.
  defp follow_business_switches(socket, token, business_id) do
    if Phoenix.LiveView.connected?(socket) and is_binary(token) do
      Events.subscribe(browser_topic(token))

      Phoenix.LiveView.attach_hook(socket, :business_switched, :handle_info, fn
        {:business_switched, ^business_id}, socket ->
          {:halt, socket}

        {:business_switched, _other}, socket ->
          {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  # Profile edits refresh the sidebar in all of the user's windows, and a
  # sign-in waiting on this device shows its prompt on every page.
  defp watch_own_account(socket) do
    if Phoenix.LiveView.connected?(socket) do
      user = socket.assigns.current_scope.user
      Accounts.subscribe_user(user)

      socket =
        case Accounts.pending_sign_in_request(user) do
          nil -> Phoenix.LiveView.clear_flash(socket, :sign_in_request)
          request -> show_sign_in_request(socket, request)
        end

      socket
      |> Phoenix.LiveView.attach_hook(:profile_updated, :handle_info, fn
        {:profile_updated, %{id: id} = updated}, socket ->
          if socket.assigns.current_scope.user.id == id do
            scope = %{socket.assigns.current_scope | user: updated}
            {:halt, Phoenix.Component.assign(socket, :current_scope, scope)}
          else
            {:cont, socket}
          end

        {:sign_in_request, request}, socket ->
          {:halt, show_sign_in_request(socket, request)}

        {:sign_in_request_closed, id}, socket ->
          {:halt, hide_sign_in_request(socket, id)}

        {:sign_in_request_expired, id}, socket ->
          {:halt, hide_sign_in_request(socket, id)}

        _message, socket ->
          {:cont, socket}
      end)
      |> Phoenix.LiveView.attach_hook(:sign_in_request_answer, :handle_event, fn
        "sign_in_request_answer", params, socket ->
          {:halt, answer_sign_in_request(socket, params)}

        _event, _params, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  defp show_sign_in_request(socket, request) do
    ms = max(DateTime.diff(request.expires_at, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), {:sign_in_request_expired, request.id}, ms)

    Phoenix.LiveView.put_flash(socket, :sign_in_request, %{
      "id" => request.id,
      "device" => QuantumBillingWeb.DeviceLabel.label(request.user_agent),
      "ip" => request.ip_address
    })
  end

  defp hide_sign_in_request(socket, id) do
    case Phoenix.Flash.get(socket.assigns.flash, :sign_in_request) do
      %{"id" => ^id} -> Phoenix.LiveView.clear_flash(socket, :sign_in_request)
      _other -> socket
    end
  end

  defp answer_sign_in_request(socket, %{"id" => id, "answer" => answer})
       when answer in ["approve", "deny"] do
    user = socket.assigns.current_scope.user
    socket = Phoenix.LiveView.clear_flash(socket, :sign_in_request)

    with {id, ""} <- Integer.parse(to_string(id)),
         {:ok, request} <-
           Accounts.answer_sign_in_request(user, id, String.to_existing_atom(answer)) do
      case answer do
        "approve" ->
          # Not the waiting device's sessions: it may already be signing in.
          user |> Accounts.replace_sessions(request.device_id) |> disconnect_sessions()
          Logger.info("[security] signed out to allow another device user=#{user.id}")

          socket
          |> Phoenix.LiveView.put_flash(:error, @replaced_message)
          |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

        "deny" ->
          Phoenix.LiveView.put_flash(
            socket,
            :info,
            "Stayed signed in. The other sign-in was refused."
          )
      end
    else
      _closed ->
        Phoenix.LiveView.put_flash(socket, :error, "That sign-in request has already closed.")
    end
  end

  defp answer_sign_in_request(socket, _params), do: socket

  # A LiveView is its own process, so point its queries at the business too.
  defp mount_current_scope(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_scope, fn ->
        {user, _} =
          if user_token = session["user_token"] do
            Accounts.get_user_by_session_token(user_token)
          end || {nil, nil}

        case Scope.for_user(user) do
          nil -> nil
          scope -> choose_business(scope, session["business_id"])
        end
      end)

    case socket.assigns.current_scope do
      %Scope{business: business, user: user} = scope ->
        Repo.put_business(business)
        Audit.put_actor(user_actor(user, socket_ip(socket)))
        Phoenix.Component.assign(socket, :current_scope, put_tax_regime(scope))

      nil ->
        Repo.put_business(nil)
        # Only the client pages behind a shared link write anything signed out.
        Audit.put_actor(%{via: "public_link", ip_address: socket_ip(socket)})
        socket
    end
  end

  # Who the audit trail names for this member's actions.
  defp user_actor(%Accounts.User{} = user, ip_address) do
    name =
      case String.trim(user.full_name || "") do
        "" -> user.email
        full_name -> full_name
      end

    %{user_id: user.id, ip_address: ip_address, name: name}
  end

  defp user_actor(_no_user, ip_address), do: %{ip_address: ip_address}

  # A nested LiveView has no connect info of its own.
  defp socket_ip(socket) do
    if socket.private[:connect_info] do
      ClientIP.from_connect_info(
        Phoenix.LiveView.get_connect_info(socket, :peer_data),
        Phoenix.LiveView.get_connect_info(socket, :x_headers)
      )
    end
  end

  # Read once per request or mount, after `Repo` points at the business, so the
  # sidebar and the GST-only pages need no query of their own.
  defp put_tax_regime(%Scope{business: %{}, tax_regime: nil} = scope),
    do: Scope.put_tax_regime(scope, Organization.tax_regime(Settings.get_organization()))

  defp put_tax_regime(scope), do: scope

  @doc "Returns the path to redirect to after log in."
  # Already logged in: redirect to settings.
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/users/settings"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for owner-only routes. Staff are redirected to the dashboard.

  The `:require_owner` on_mount hook covers LiveViews.
  """
  def require_owner(conn, _opts) do
    if Scope.owner?(conn.assigns[:current_scope]) do
      conn
    else
      conn
      |> put_flash(:error, @owner_only_message)
      |> redirect(to: ~p"/dashboard")
      |> halt()
    end
  end

  @doc """
  Plug for the super admin's routes. Anyone else gets a 404, so the pages
  cannot be discovered. The `:require_admin` on_mount hook covers LiveViews.
  """
  def require_admin(conn, _opts) do
    if Scope.admin?(conn.assigns[:current_scope]),
      do: conn,
      else: raise(QuantumBillingWeb.NotFoundError)
  end

  @doc """
  Plug for business pages: while maintenance mode is on, everyone but super
  admins is sent to /maintenance.
  """
  def check_maintenance(conn, _opts) do
    if under_maintenance?(conn.assigns[:current_scope]) do
      conn |> redirect(to: ~p"/maintenance") |> halt()
    else
      conn
    end
  end

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> maybe_explain_redirect()
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  @doc "Plug for file routes: signed-out visitors get the Forbidden page instead of a redirect."
  def require_user_or_forbid(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      forbidden(conn)
    end
  end

  @doc "Renders the Forbidden page and halts. Signed-in users are sent to the picker."
  def forbidden(conn) do
    signed_in? = match?(%{user: %{}}, conn.assigns[:current_scope])

    conn =
      if signed_in?, do: conn, else: maybe_store_return_to(conn)

    conn
    |> put_status(:forbidden)
    |> put_resp_header("cache-control", "no-store")
    |> put_format("html")
    |> put_view(html: QuantumBillingWeb.ErrorHTML)
    |> put_root_layout(html: false)
    |> put_layout(html: false)
    |> render(:"403",
      signed_in?: signed_in?,
      redirect_to: if(signed_in?, do: ~p"/businesses", else: ~p"/users/log-in")
    )
    |> halt()
  end

  # Only when the visitor asked for a specific page, and nothing else explains it.
  defp maybe_explain_redirect(conn) do
    if current_path(conn) == "/" or Phoenix.Flash.get(conn.assigns[:flash] || %{}, :error) do
      conn
    else
      put_flash(conn, :error, "You must log in to access this page.")
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
