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
  @remember_me_options [
    encrypt: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # Tokens older than this are reissued.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @pending_two_factor_key :pending_two_factor
  @pending_two_factor_ttl_seconds 600

  @doc """
  Holds a password-verified user at the door until they pass the second factor.

  The session is renewed first — the same fixation defence `log_in_user/3`
  relies on — and then carries only an id, a timestamp and the sign-in intent.
  Crucially it does **not** write `:user_token`, so
  `fetch_current_scope_for_user/2` still sees a signed-out visitor: this marker
  is a note about an attempt in progress, never a credential.
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

  @doc """
  The user waiting on a second factor, or `nil`.

  Returns `nil` for an expired attempt, so an abandoned half-login cannot be
  finished hours later from the same browser.
  """
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

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      QuantumBillingWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    # To the sign-in page: / is protected and would add a "must log in" flash.
    |> redirect(to: ~p"/users/log-in")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
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
  Chooses the business this request works in.

  The one named by `"business_id"` in the session, if the user is still a
  member and it is not archived; otherwise, when they belong to exactly one,
  that one, written back to the session so the next request need not guess.
  With several and no valid choice, none is chosen and `require_business/2`
  sends them to the picker.

  The choice goes on the scope and into `QuantumBilling.Repo`, which is what
  points every query in the request at the business's own schema.
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

  # One query: the user's businesses, from which the chosen one is picked.
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

  @doc """
  Plug for routes that work inside a business: sends a user who has not chosen
  one to the picker.
  """
  def require_business(conn, _opts) do
    if conn.assigns.current_scope.business do
      conn
    else
      conn
      |> redirect(to: ~p"/businesses")
      |> halt()
    end
  end

  @doc """
  The PubSub topic for one signed-in browser.

  Keyed by a hash of the session token rather than the token itself: topic
  names show up in logs and the LiveDashboard, and the token is a credential.
  """
  def browser_topic(token) when is_binary(token) do
    "browser:" <> Base.url_encode64(:crypto.hash(:sha256, token), padding: false)
  end

  @doc """
  Tells this browser's other tabs that it now works in `business_id`; each
  reloads. See `on_mount(:require_business, ...)`.
  """
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

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # Called on login, in sudo mode, or to renew a session.
  # A new session is cleared first to prevent fixation.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # Renews the session ID and erases the session to avoid fixation attacks.
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
  Disconnects every open LiveView `user` has, in every browser.

  For a change to what they may do — removed from a business, an owner made
  staff. Membership is checked when a LiveView mounts, so an already-open page
  would otherwise go on acting with the access it mounted with. Disconnected,
  it reconnects at once, mounts again, and is held to the new rules. Their
  sessions themselves survive: they stay signed in to whatever else they may
  still use.
  """
  def disconnect_user(%Accounts.User{} = user) do
    user |> Accounts.list_user_session_tokens() |> disconnect_sessions()
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

    * `:require_business` - Redirects to the business picker when none is
      chosen; otherwise follows a switch made in another tab of this browser.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule QuantumBillingWeb.PageLive do
        use QuantumBillingWeb, :live_view

        on_mount {QuantumBillingWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{QuantumBillingWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
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

  # A switch in another tab reloads this one into the new business. A full
  # redirect, not a navigation: the business this socket works in was fixed
  # from the session when it mounted, and only a page load reads it again.
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

  # Also points this process's queries at the scope's business: a LiveView is
  # a process of its own, and the plug only set it for the HTTP request.
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
  # the user was already logged in, redirect to settings
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/users/settings"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes only an owner may reach.

  Both this and `on_mount(:require_owner, ...)` exist, and both are needed: the
  plug covers controller routes, and the hook covers LiveViews, which a plug
  does not protect once the socket connects.

  A staff account is redirected to the dashboard rather than shown a 404. They
  are legitimately signed in; they just do not administer the installation, and
  pretending the page does not exist would be a worse answer than saying so.
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

  @doc """
  Plug for routes that serve a file. Someone not signed in gets the Forbidden
  page, which sends them to sign in, rather than an immediate redirect.
  """
  def require_user_or_forbid(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      forbidden(conn)
    end
  end

  @doc """
  Answers with the Forbidden page and halts.

  Its refresh goes to sign-in, and sign-in comes back to this URL. Someone
  already signed in goes to the business picker instead: the log-in page would
  only bounce them back into the application.
  """
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
