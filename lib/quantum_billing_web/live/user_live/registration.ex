defmodule QuantumBillingWeb.UserLive.Registration do
  @moduledoc """
  Creating an account — which is not open to the public.

  Every account on this installation shares one dataset: there is no per-user
  scoping on invoices or clients, because the application bills for one
  business. So an account is full access to the books, and this page used to
  hand one to anybody who found the URL. Confirming an email proves you own
  that mailbox; it does not prove the business wants you in its ledger.

  So the page has three states: it takes the very first account on a fresh
  installation (which becomes the owner), it takes an invited address when
  `?token=` carries a live invitation, and otherwise it explains that an
  invitation is needed and shows no form at all.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.UserLive.AuthComponents

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <:top_link>
        <.link navigate={~p"/users/log-in"} class="hover:underline">Login</.link>
      </:top_link>

      <Layouts.auth_heading
        title={if @open?, do: "Create an account", else: "Registration is by invitation"}
        subtitle={
          cond do
            @bootstrap? ->
              "This installation has no accounts yet. The first one you create owns it."

            @open? ->
              "You were invited as #{@invited_email}. Set a username and a password to finish."

            true ->
              "This installation does not accept public sign-ups."
          end
        }
      />

      <div :if={not @open?} class="grid gap-4 text-sm text-base-content/70">
        <p>
          Accounts here share one set of books, so they are handed out rather than
          claimed. Ask an owner to invite you — they can do it from
          <span class="font-medium">Settings &rsaquo; Team</span>
          — and you will get a
          link by email.
        </p>

        <p>
          Already have an account? <.link
            navigate={~p"/users/log-in"}
            class="font-medium hover:underline"
          >Log in</.link>.
        </p>
      </div>

      <div :if={@open?} class="grid gap-6">
        <.form
          for={@form}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
          class="space-y-3"
        >
          <.input
            field={@form[:username]}
            type="text"
            placeholder="Username"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
            class={input_class()}
            error_class="border-red-500"
          />
          <%!--
          Read-only when invited: the invitation is bound to one address, and
          letting it be edited here would only burn the invitation on a
          mismatch. The server re-checks it either way — a readonly attribute
          is a courtesy, not a control.
          --%>
          <.input
            field={@form[:email]}
            type="email"
            placeholder="name@example.com"
            autocomplete="email"
            spellcheck="false"
            required
            readonly={not @bootstrap?}
            class={input_class()}
            error_class="border-red-500"
          />
          <.input
            field={@form[:password]}
            type="password"
            placeholder="Password"
            autocomplete="new-password"
            spellcheck="false"
            required
            class={input_class()}
            error_class="border-red-500"
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            placeholder="Confirm password"
            autocomplete="new-password"
            spellcheck="false"
            required
            class={input_class()}
            error_class="border-red-500"
          />
          <p class="text-xs text-base-content/60">Use at least 8 characters.</p>

          <.button phx-disable-with="Creating account..." class={primary_button_class()}>
            Create Account
          </.button>
        </.form>
      </div>
      <.legal_note />
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: QuantumBillingWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(params, _session, socket) do
    token = params["token"]
    bootstrap? = Accounts.bootstrap?()
    invited_email = Accounts.invited_email(token)

    changeset =
      Accounts.change_user_registration(%User{}, %{"email" => invited_email})

    {:ok,
     socket
     |> assign(:invitation_token, token)
     |> assign(:bootstrap?, bootstrap?)
     |> assign(:invited_email, invited_email)
     |> assign(:open?, bootstrap? or not is_nil(invited_email))
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    # The invitation decides the address, not the form. Even with the readonly
    # attribute removed in the browser, what gets registered is what was
    # invited.
    user_params =
      case socket.assigns.invited_email do
        nil -> user_params
        email -> Map.put(user_params, "email", email)
      end

    case Accounts.register_user_with_password(user_params, socket.assigns.invitation_token) do
      {:ok, user} ->
        # The account is already saved by this point, so a relay that will not
        # take the message must not take the page down with it. Matching
        # `{:ok, _}` here left the account created, unconfirmed and unable to
        # ever confirm itself, behind a crashed LiveView — which is how the
        # first unconfirmed accounts in this database got there.
        case Accounts.deliver_user_confirmation_instructions(
               user,
               &url(~p"/users/confirm/#{&1}")
             ) do
          {:ok, _email} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Account created. We sent a confirmation link to #{user.email} — " <>
                 "open it to activate your account."
             )
             |> push_navigate(to: ~p"/users/log-in")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               "Your account was created, but the confirmation email could not be " <>
                 "sent (#{reason}). Ask an administrator to check Settings > SMTP, " <>
                 "then use “Forgot password?” to get a fresh link."
             )
             |> push_navigate(to: ~p"/users/log-in")}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
