defmodule QuantumBillingWeb.InvitationLive do
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_invitation_by_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "This invitation link is invalid or has expired.")
         |> redirect(to: ~p"/")}

      invitation ->
        user = get_current_user(socket)

        cond do
          user && String.downcase(user.email) == String.downcase(invitation.email) ->
            {:ok,
             assign(socket,
               page_title: "Accept invitation",
               invitation: invitation,
               token: token,
               mode: :respond
             )}

          user ->
            {:ok,
             assign(socket,
               page_title: "Wrong account",
               invitation: invitation,
               token: token,
               mode: :mismatch,
               signed_in_email: user.email
             )}

          Accounts.get_user_by_email(invitation.email) ->
            return_to = ~p"/invitations/#{token}"

            {:ok,
             socket
             |> put_flash(:info, "Sign in with #{invitation.email} to review your invitation.")
             |> redirect(to: ~p"/users/log-in?#{[return_to: return_to]}")}

          true ->
            {:ok, redirect(socket, to: ~p"/users/register?#{[token: token]}")}
        end
    end
  end

  @impl true
  def handle_event("accept", _params, socket) do
    user = get_current_user(socket)
    %{invitation: invitation} = socket.assigns

    case Accounts.accept_invitation(user, invitation) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, "You joined #{invitation.business.name}.")
         |> redirect(to: ~p"/businesses")}

      {:error, :email_mismatch} ->
        {:noreply, put_flash(socket, :error, "This invitation belongs to a different email.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not accept this invitation.")}
    end
  end

  @impl true
  def handle_event("decline", _params, socket) do
    user = get_current_user(socket)
    %{invitation: invitation} = socket.assigns

    case Accounts.decline_invitation(user, invitation) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation to #{invitation.business.name} declined.")
         |> redirect(to: ~p"/businesses")}

      {:error, :email_mismatch} ->
        {:noreply, put_flash(socket, :error, "This invitation belongs to a different email.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not decline this invitation.")}
    end
  end

  defp get_current_user(socket) do
    cond do
      scope = socket.assigns[:current_scope] -> scope.user
      user = socket.assigns[:current_user] -> user
      true -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-md py-12 px-4">
      <div :if={@mode == :respond} class="rounded-xl border border-base-300 bg-base-100 p-6 shadow-sm">
        <h1 class="text-lg font-semibold">Team invitation</h1>
        <p class="mt-2 text-sm text-base-content/75">
          You have been invited to join <strong>{@invitation.business.name}</strong> as
          <strong>{@invitation.role}</strong>.
        </p>

        <div class="mt-6 flex items-center gap-3">
          <button type="button" phx-click="accept" class="btn btn-primary btn-sm">
            Accept invitation
          </button>
          <button type="button" phx-click="decline" class="btn btn-ghost btn-sm">
            Decline
          </button>
        </div>
      </div>

      <div :if={@mode == :mismatch} class="rounded-xl border border-base-300 bg-base-100 p-6 shadow-sm">
        <h1 class="text-lg font-semibold">Different account signed in</h1>
        <p class="mt-2 text-sm text-base-content/75">
          This invitation was sent to <strong>{@invitation.email}</strong>, but you are signed in as
          <strong>{@signed_in_email}</strong>. Sign out and sign in with {@invitation.email} to respond.
        </p>
      </div>
    </div>
    """
  end
end