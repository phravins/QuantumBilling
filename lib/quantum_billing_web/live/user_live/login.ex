defmodule QuantumBillingWeb.UserLive.Login do
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.UserLive.AuthComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <:top_link>
        <.link id="auth-top-link" navigate={~p"/users/register"} class={top_link_class()}>
          Sign up
        </.link>
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
          <div class="flex items-center justify-between gap-2">
            <.input
              field={f[:remember_me]}
              type="checkbox"
              label="Remember me"
              class="size-4 rounded border-base-300 text-base-content focus:outline-none focus:border-(--qb-field-focus)"
            />
            <.link
              id="forgot-password"
              navigate={~p"/users/forgot-password"}
              class="inline-flex h-8 shrink-0 items-center rounded-field border border-base-300 bg-base-100 px-3 text-xs font-medium text-base-content/80 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
            >
              Forgot password?
            </.link>
          </div>
          <.button class={primary_button_class()}>
            Sign In
          </.button>
        </.form>
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
