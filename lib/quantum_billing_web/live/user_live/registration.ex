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

      <div class="space-y-6">
        <div class="space-y-2 text-center">
          <h1 class="text-3xl font-bold tracking-tight">Create an account</h1>
          <p class="text-base-content/60">Enter your email below to create your account</p>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            placeholder="name@example.com"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.button phx-disable-with="Creating account..." class="btn btn-neutral mt-2 w-full">
            Sign Up with Email
          </.button>
        </.form>

        <.or_divider />

        <.github_button />

        <.legal_note />
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: QuantumBillingWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
