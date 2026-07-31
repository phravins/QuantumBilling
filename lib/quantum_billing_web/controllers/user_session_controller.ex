defmodule QuantumBillingWeb.UserSessionController do
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.TwoFactor
  alias QuantumBillingWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)
        finish_login(conn, user, user_params, info)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    case Accounts.get_user_by_email_and_password(email, password) do
      %{confirmed_at: nil} ->
        conn
        |> put_flash(:error, "Please confirm your email first — check your inbox for the link.")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      nil ->
        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        conn
        |> put_flash(:error, "Invalid email or password")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      user ->
        finish_login(conn, user, user_params, info)
    end
  end

  # Both doors — password and magic link — end here, which is the point: a
  # second factor that only guarded one of them would be no second factor at
  # all for anyone holding the inbox.
  #
  # The exception is a caller that is already signed in as this user, which is
  # `update_password/2` re-issuing a session. Challenging there would ask for a
  # code moments after the account was proven, to no benefit.
  defp finish_login(conn, user, user_params, info) do
    cond do
      already_signed_in_as?(conn, user) ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      TwoFactor.enabled?(user) ->
        conn
        |> UserAuth.stash_pending_two_factor(user, user_params)
        |> redirect(to: ~p"/users/two-factor")

      true ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)
    end
  end

  defp already_signed_in_as?(conn, user) do
    case conn.assigns[:current_scope] do
      %{user: %{id: id}} -> id == user.id
      _ -> false
    end
  end

  @doc """
  Verifies the second factor for a sign-in held by
  `UserAuth.stash_pending_two_factor/3`.

  The check lives here rather than in the LiveView so there is exactly one
  authoritative verification — a recovery code is single use, and checking it
  in two places would burn it twice.
  """
  def verify_two_factor(conn, %{"user" => %{"code" => code}}) do
    case UserAuth.pending_two_factor(conn) do
      nil ->
        conn
        |> put_flash(:error, "That sign-in attempt has expired. Please start again.")
        |> redirect(to: ~p"/users/log-in")

      {user, pending} ->
        case TwoFactor.verify(user, code) do
          {:ok, user} ->
            conn
            |> put_flash(:info, "Welcome back!")
            |> UserAuth.complete_two_factor_login(user, pending)

          {:error, _reason} ->
            conn
            |> put_flash(:error, "That code is not valid. Please try again.")
            |> redirect(to: ~p"/users/two-factor")
        end
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
