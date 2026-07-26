defmodule QuantumBillingWeb.UserConfirmationController do
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Accounts

  @doc """
  Activates the account behind a sign-up confirmation link.

  Confirming deliberately does not log anybody in: whoever clicks the link has to
  know the password chosen at sign-up, so an account created with someone else's
  email address cannot be taken over by them opening the email.
  """
  def confirm(conn, %{"token" => token}) do
    case Accounts.confirm_user_by_token(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Account confirmed. You can sign in now.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Confirmation link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end
end
