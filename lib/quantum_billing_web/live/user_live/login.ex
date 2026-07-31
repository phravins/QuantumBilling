defmodule QuantumBillingWeb.UserLive.Login do
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.UserLive.AuthComponents

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
        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="space-y-3"
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
          <.input
            field={f[:password]}
            type="password"
            placeholder="Password"
            autocomplete="current-password"
            spellcheck="false"
            required
            class={input_class()}
            error_class="border-red-500"
          />
          <.input
            field={f[:remember_me]}
            type="checkbox"
            label="Remember me"
            class="size-4 rounded border-zinc-300 text-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-950/10"
          />
          <.button class={primary_button_class()}>
            Sign In
          </.button>
        </.form>

        <.or_divider />

        <.github_button />
      </div>

      <.legal_note />
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
end
