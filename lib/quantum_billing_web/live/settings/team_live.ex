defmodule QuantumBillingWeb.SettingsLive.Team do
  @moduledoc """
  Owner-only: who works in the current business, and who has been invited to.

  Registration is invite-only, so this page is the only way a second account
  comes into existence. It exists because the alternative — open sign-up — gave
  anyone who found the address full access to the books.

  Everything here is the current business's. Inviting an address that already
  has an account adds that person straight away — they sign in as they always
  have and find the business in their switcher. Removing someone takes away
  this business only; their account and their other businesses stay.

  Both the route and the `on_mount` hook require an owner. The hook is what
  actually protects this page: a plug alone does not, once the socket connects.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Accounts
  alias QuantumBilling.Businesses.Membership

  @last_owner_message "This is the only owner. Make somebody else an owner first."

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
    business = socket.assigns.current_scope.business

    socket
    |> assign(:members, Accounts.list_members(business))
    |> assign(:invitations, Accounts.list_invitations(business))
    |> assign(:owner_count, Accounts.count_owners(business))
  end

  def handle_event("invite", %{"invitation" => %{"email" => email, "role" => role}}, socket) do
    %{business: business, user: inviter} = socket.assigns.current_scope
    url_fun = fn token -> url(~p"/users/register?#{[token: token]}") end

    case Accounts.invite(business, email, role, inviter, url_fun) do
      {:ok, {:invited, invitation}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation sent to #{invitation.email}.")
         |> assign(:invite_email, "")
         |> load_team()}

      {:ok, {:added, membership}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{membership.user.email} already had an account and is now on the team."
         )
         |> assign(:invite_email, "")
         |> load_team()}

      {:error, :already_member} ->
        {:noreply, put_flash(socket, :error, "That person is already on the team.")}

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
    case Accounts.get_invitation(socket.assigns.current_scope.business, id) do
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
    with %Membership{user: user} <- find_member(socket, id) do
      case Accounts.set_role(socket.assigns.current_scope.business, user, role) do
        {:ok, _membership} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{user.email} is now #{role}.")
           |> load_team()}

        {:error, :last_owner} ->
          {:noreply, put_flash(socket, :error, @last_owner_message)}

        {:error, _reason} ->
          {:noreply,
           socket |> put_flash(:error, "That role could not be changed.") |> load_team()}
      end
    else
      nil -> {:noreply, load_team(socket)}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    with %Membership{user: user} <- find_member(socket, id) do
      case Accounts.remove_member(socket.assigns.current_scope.business, user) do
        {:ok, _membership} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{user.email} no longer has access to this business.")
           |> load_team()}

        {:error, :last_owner} ->
          {:noreply, put_flash(socket, :error, @last_owner_message)}

        {:error, _reason} ->
          {:noreply, load_team(socket)}
      end
    else
      nil -> {:noreply, load_team(socket)}
    end
  end

  # Looked up among the members this page loaded, so an id from elsewhere does nothing.
  defp find_member(socket, user_id) do
    Enum.find(socket.assigns.members, &(to_string(&1.user_id) == user_id))
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      active_sub={:team}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        Team
        <:subtitle>
          Who can work in {@current_scope.business.name}. Everyone here shares its books,
          so a place on the team is full access to its invoices and clients.
        </:subtitle>
      </.header>

      <.card class="mb-3">
        <h3 class="mb-1 text-sm font-semibold">Invite someone</h3>
        <p class="mb-3 text-xs text-base-content/60">
          Someone who already has an account is added straight away. Anyone else gets a
          sign-up link that works once, expires in {QuantumBilling.Accounts.Invitation.validity_days()} days,
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
        <h3 class="mb-3 text-sm font-semibold">Members</h3>

        <table class="table table-fixed">
          <thead>
            <tr class={table_head_class()}>
              <th>Email</th>
              <th class="w-32">Role</th>
              <th class="w-28">Status</th>
              <th class="w-56">Change</th>
            </tr>
          </thead>

          <tbody>
            <tr
              :for={%{user: user} = member <- @members}
              id={"user-#{user.id}"}
              class={table_row_class()}
            >
              <td class="truncate">
                {user.email}
                <span :if={user.id == @current_scope.user.id} class="text-xs text-base-content/45">
                  (you)
                </span>
              </td>

              <td>
                <.status_badge status={if Membership.owner?(member), do: "Active", else: "Inactive"} />
                <span class="ml-1 text-xs">{member.role}</span>
              </td>

              <td class="text-xs text-base-content/60">
                {if user.confirmed_at, do: "Confirmed", else: "Pending"}
              </td>

              <td>
                <button
                  :if={not Membership.owner?(member)}
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
                  :if={Membership.owner?(member) and @owner_count > 1}
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
                  :if={Membership.owner?(member) and @owner_count == 1}
                  class="text-xs text-base-content/45"
                >
                  Only owner
                </span>

                <button
                  :if={not Membership.owner?(member) or @owner_count > 1}
                  type="button"
                  id={"remove-member-#{user.id}"}
                  phx-click="remove"
                  phx-value-id={user.id}
                  data-confirm={"Remove #{user.email} from #{@current_scope.business.name}? Their account and any other businesses stay as they are."}
                  class="btn btn-xs btn-ghost text-error"
                >
                  Remove
                </button>
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
