defmodule QuantumBillingWeb.UserLive.Login do
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.UserLive.AuthComponents

  alias QuantumBilling.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <:top_link>
        <.link navigate={~p"/users/register"} class="hover:underline">Sign up</.link>
      </:top_link>

      <div class="space-y-6">
        <div class="space-y-2 text-center">
          <h1 class="text-3xl font-bold tracking-tight">Welcome back</h1>
          <p class="text-base-content/60">
            <%= if @current_scope do %>
              You need to reauthenticate to perform sensitive actions on your account.
            <% else %>
              Enter your email below to sign in to your account
            <% end %>
          </p>
        </div>

        <div :if={local_mail_adapter?()} class="alert alert-info text-sm">
          <.icon name="hero-information-circle" class="size-5 shrink-0" />
          <span>
            Local mail adapter — magic links appear in <.link href="/dev/mailbox" class="underline">the mailbox</.link>.
          </span>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            placeholder="name@example.com"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-neutral mt-2 w-full">
            Sign In with Email
          </.button>
        </.form>

        <.or_divider />

        <.github_button />

        <details class="group">
          <summary class="cursor-pointer list-none text-center text-sm text-base-content/60 hover:underline">
            Sign in with a password instead
          </summary>

          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
            class="mt-4"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              spellcheck="false"
            />
            <.button class="btn btn-neutral w-full" name={@form[:remember_me].name} value="true">
              Log in and stay logged in
            </.button>
            <.button class="btn btn-soft mt-2 w-full">
              Log in only this time
            </.button>
          </.form>
        </details>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:quantum_billing, QuantumBilling.Mailer)[:adapter] ==
      Swoosh.Adapters.Local
  end
end
