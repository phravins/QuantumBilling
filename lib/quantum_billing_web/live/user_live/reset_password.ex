defmodule QuantumBillingWeb.UserLive.ResetPassword do
  @moduledoc """
  Sets a new password from the link in a reset email.

  The token is resolved once, on mount: an expired or already-spent link never
  renders the form at all, rather than failing after the password is typed.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.UserLive.AuthComponents

  alias QuantumBilling.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <:top_link>
        <.link navigate={~p"/users/log-in"} class="hover:underline">Back to login</.link>
      </:top_link>

      <Layouts.auth_heading
        title="Set a new password"
        subtitle={"Choose a new password for #{@user.email}"}
      />
      <div class="grid gap-6">
        <.form
          for={@form}
          id="reset_password_form"
          phx-submit="save"
          phx-change="validate"
          class="space-y-3"
        >
          <.input
            field={@form[:password]}
            type="password"
            placeholder="New password"
            autocomplete="new-password"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
            class={input_class()}
            error_class="border-red-500"
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            placeholder="Confirm new password"
            autocomplete="new-password"
            spellcheck="false"
            required
            class={input_class()}
            error_class="border-red-500"
          />
          <p class="text-xs text-base-content/60">Use at least 8 characters.</p>

          <.button phx-disable-with="Saving..." class={primary_button_class()}>
            Reset password
          </.button>
        </.form>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_reset_password_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "That reset link is invalid or has expired. Please request a new one."
         )
         |> push_navigate(to: ~p"/users/forgot-password")}

      user ->
        changeset = Accounts.change_user_password(user, %{}, hash_password: false)

        {:ok,
         socket
         |> assign(user: user, token: token)
         |> assign_form(changeset)}
    end
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, {_user, _expired_tokens}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password updated. You can sign in with it now.")
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
