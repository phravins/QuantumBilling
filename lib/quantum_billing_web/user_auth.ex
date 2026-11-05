defmodule QuantumBillingWeb.UserAuth do
  use QuantumBillingWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.Events
  alias QuantumBilling.InstallationSettings
  alias QuantumBilling.Repo

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
    |> log_in_user(user, %{"remember_me" => to_string(pending["remember_me"])})
  end

  defp maybe_restore_return_to(conn, nil), do: conn
  defp maybe_restore_return_to(conn, path), do: put_session(conn, :user_return_to, path)

  @doc "Logs the user out and clears the session."
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

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
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  @doc """
  Chooses the business this request works in and points `Repo` at its schema.

  Uses the session's `"business_id"` if still valid, or the user's only
  business. With several and no valid choice, none is chosen.
  """
  def fetch_current_business(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: %Accounts.User{}} = scope ->
        scope = choose_business(scope, get_session(conn, :business_id))
        Repo.put_business(scope.business)

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
    token = Accounts.generate_user_session_token(user)
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
        {:cont, watch_own_account(socket)}

      true ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
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

  # Profile edits refresh the sidebar in all of the user's windows.
  defp watch_own_account(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Accounts.subscribe_user(socket.assigns.current_scope.user)

      Phoenix.LiveView.attach_hook(socket, :profile_updated, :handle_info, fn
        {:profile_updated, %{id: id} = updated}, socket ->
          if socket.assigns.current_scope.user.id == id do
            scope = %{socket.assigns.current_scope | user: updated}
            {:halt, Phoenix.Component.assign(socket, :current_scope, scope)}
          else
            {:cont, socket}
          end

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

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
      %Scope{business: business} -> Repo.put_business(business)
      nil -> Repo.put_business(nil)
    end

    socket
  end

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

  # Only when the visitor asked for a specific page.
  defp maybe_explain_redirect(conn) do
    if current_path(conn) == "/" do
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
