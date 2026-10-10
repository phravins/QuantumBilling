defmodule QuantumBillingWeb.SettingsLive.Team do
  @moduledoc """
  Owner-only: who has an account on this installation, and who has been
  invited.

  Registration is invite-only, so this page is the only way a second account
  comes into existence. It exists because the alternative — open sign-up — gave
  anyone who found the address full access to the books.

  Both the route and the `on_mount` hook require an owner. The hook is what
  actually protects this page: a plug alone does not, once the socket connects.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.User

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Team")
     |> assign(:active_nav, :settings)
     |> assign(:invite_email, "")
     |> assign(:invite_role, "staff")
     |> load_team()}
  end

  defp load_team(socket) do
    socket
    |> assign(:users, Accounts.list_users())
    |> assign(:invitations, Accounts.list_invitations())
    |> assign(:owner_count, Accounts.count_owners())
  end

  def handle_event("invite", %{"invitation" => %{"email" => email, "role" => role}}, socket) do
    url_fun = fn token -> url(~p"/users/register?#{[token: token]}") end

    case Accounts.invite(email, role, socket.assigns.current_scope.user, url_fun) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation sent to #{invitation.email}.")
         |> assign(:invite_email, "")
         |> load_team()}

      {:error, :already_registered} ->
        {:noreply, put_flash(socket, :error, "That address already has an account.")}

      {:error, :invalid_email} ->
        {:noreply, put_flash(socket, :error, "Enter an email address to invite.")}

      {:error, {:delivery_failed, message}} ->
        {:noreply,
         socket
         |> put_flash(:error, "The invitation email could not be sent: #{message}")
         |> load_team()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That invitation could not be sent.")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Accounts.get_invitation(id) do
      nil ->
        {:noreply, load_team(socket)}

      invitation ->
        {:ok, _} = Accounts.revoke_invitation(invitation)

        {:noreply,
         socket
         |> put_flash(:info, "Invitation to #{invitation.email} withdrawn.")
         |> load_team()}
    end
  end

  def handle_event("set_role", %{"id" => id, "role" => role}, socket) do
    user = Enum.find(socket.assigns.users, &(to_string(&1.id) == id))

    cond do
      is_nil(user) ->
        {:noreply, load_team(socket)}

      true ->
        case Accounts.set_role(user, role) do
          {:ok, _user} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{user.email} is now #{role}.")
             |> load_team()}

          {:error, :last_owner} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This is the only owner. Make somebody else an owner first."
             )}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "That role could not be changed.")}
        end
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        Team
        <:subtitle>
          Who can sign in to this installation. Everyone here shares the same books,
          so an account is full access to your invoices and clients.
        </:subtitle>
      </.header>

      <.card class="mb-3">
        <h3 class="mb-1 text-sm font-semibold">Invite someone</h3>
        <p class="mb-3 text-xs text-base-content/60">
          Registration is closed — this is the only way to add an account. The link
          works once, expires in {QuantumBilling.Accounts.Invitation.validity_days()} days,
          and only works for the address you enter.
        </p>

        <form id="invite-form" phx-submit="invite" class="flex flex-col gap-2 sm:flex-row">
          <input
            type="email"
            name="invitation[email]"
            value={@invite_email}
            required
            placeholder="name@company.com"
            class={[filter_input_class(), "pl-3 sm:max-w-xs"]}
          />

          <select name="invitation[role]" class={form_select_class() <> " sm:w-40"}>
            <option value="staff">Staff</option>
            <option value="owner">Owner</option>
          </select>

          <button type="submit" class={action_button_class()}>
            <.icon name="hero-paper-airplane" class="size-4" /> Send invitation
          </button>
        </form>
      </.card>

      <.card class="mb-3">
        <h3 class="mb-3 text-sm font-semibold">Accounts</h3>

        <table class="table table-fixed">
          <thead>
            <tr class={table_head_class()}>
              <th>Email</th>
              <th class="w-32">Role</th>
              <th class="w-28">Status</th>
              <th class="w-44">Change role</th>
            </tr>
          </thead>

          <tbody>
            <tr :for={user <- @users} id={"user-#{user.id}"} class={table_row_class()}>
              <td class="truncate">
                {user.email}
                <span :if={user.id == @current_scope.user.id} class="text-xs text-base-content/45">
                  (you)
                </span>
              </td>

              <td>
                <.status_badge status={if User.owner?(user), do: "Active", else: "Inactive"} />
                <span class="ml-1 text-xs">{user.role}</span>
              </td>

              <td class="text-xs text-base-content/60">
                {if user.confirmed_at, do: "Confirmed", else: "Pending"}
              </td>

              <td>
                <button
                  :if={not User.owner?(user)}
                  type="button"
                  phx-click="set_role"
                  phx-value-id={user.id}
                  phx-value-role="owner"
                  data-confirm={"Make #{user.email} an owner? Owners can administer accounts, credentials and the full data export."}
                  class="btn btn-xs btn-ghost"
                >
                  Make owner
                </button>

                <button
                  :if={User.owner?(user) and @owner_count > 1}
                  type="button"
                  phx-click="set_role"
                  phx-value-id={user.id}
                  phx-value-role="staff"
                  data-confirm={"Make #{user.email} staff? They will lose access to accounts, credentials and the data export."}
                  class="btn btn-xs btn-ghost"
                >
                  Make staff
                </button>

                <span
                  :if={User.owner?(user) and @owner_count == 1}
                  class="text-xs text-base-content/45"
                >
                  Only owner
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </.card>

      <.card>
        <h3 class="mb-3 text-sm font-semibold">Invitations</h3>

        <.empty_state
          :if={@invitations == []}
          icon="hero-envelope"
          title="No invitations"
          description="Invitations you send appear here until they are used or withdrawn."
        />

        <table :if={@invitations != []} class="table table-fixed">
          <thead>
            <tr class={table_head_class()}>
              <th>Email</th>
              <th class="w-24">Role</th>
              <th class="w-32">State</th>
              <th class="w-28">Actions</th>
            </tr>
          </thead>

          <tbody>
            <tr
              :for={invitation <- @invitations}
              id={"invitation-#{invitation.id}"}
              class={table_row_class()}
            >
              <td class="truncate">{invitation.email}</td>
              <td class="text-xs">{invitation.role}</td>

              <td class="text-xs text-base-content/60">
                {cond do
                  invitation.accepted_at -> "Accepted"
                  QuantumBilling.Accounts.Invitation.pending?(invitation) -> "Pending"
                  true -> "Expired"
                end}
              </td>

              <td>
                <button
                  :if={is_nil(invitation.accepted_at)}
                  type="button"
                  phx-click="revoke"
                  phx-value-id={invitation.id}
                  data-confirm="Withdraw this invitation?"
                  class="btn btn-xs btn-ghost text-error"
                >
                  Withdraw
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </Layouts.app>
    """
  end
end
