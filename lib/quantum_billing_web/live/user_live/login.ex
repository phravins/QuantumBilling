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

      <Layouts.auth_heading
        title="Welcome back"
        subtitle={
          if @current_scope,
            do: "You need to reauthenticate to perform sensitive actions on your account.",
            else: "Enter your email below to sign in to your account"
        }
      />

      <div class="grid gap-6">
        <p :if={local_mail_adapter?()} class="text-center text-xs text-zinc-500">
          Local mail adapter — magic links appear in <.link
            href="/dev/mailbox"
            class="underline underline-offset-4"
          >the mailbox</.link>.
        </p>

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
            class={input_class()}
            error_class="border-red-500"
          />
          <.button class={primary_button_class()}>
            Sign In with Email
          </.button>
        </.form>

        <.or_divider />

        <.github_button />

        <details class="group">
          <summary class="cursor-pointer list-none text-center text-sm text-zinc-500 hover:underline">
            Sign in with a password instead
          </summary>

          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
            class="mt-4 space-y-2"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              placeholder="name@example.com"
              autocomplete="username"
              spellcheck="false"
              required
              class={input_class()}
              error_class="border-red-500"
            />
            <.input
              field={@form[:password]}
              type="password"
              placeholder="Password"
              autocomplete="current-password"
              spellcheck="false"
              class={input_class()}
              error_class="border-red-500"
            />
            <.button
              class={primary_button_class()}
              name={@form[:remember_me].name}
              value="true"
            >
              Log in and stay logged in
            </.button>
            <.button class={outline_button_class()}>
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
