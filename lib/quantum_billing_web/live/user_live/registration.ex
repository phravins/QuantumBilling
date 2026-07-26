defmodule QuantumBillingWeb.UserLive.Registration do
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
        title="Create an account"
        subtitle="Enter your details below to create your account"
      />

      <div class="grid gap-6">
        <.form
          for={@form}
          id="registration_form"
          action={~p"/users/log-in?_action=registered"}
          method="post"
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
          class="space-y-3"
        >
          <.input
            field={@form[:email]}
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

          <p class="text-xs text-zinc-500">Use at least 12 characters.</p>

          <.button phx-disable-with="Creating account..." class={primary_button_class()}>
            Create Account
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
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: QuantumBillingWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{})

    {:ok, socket |> assign(trigger_submit: false) |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user_with_password(user_params) do
      {:ok, _user} ->
        # The rendered form still holds the credentials the user typed, so
        # triggering it posts them to the session controller, which signs them in.
        changeset = Accounts.change_user_registration(%User{}, user_params)

        {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

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
