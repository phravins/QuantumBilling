defmodule QuantumBillingWeb.UserLive.ForgotPassword do
  @moduledoc """
  Asks for the address to send a password reset link to.

  The answer is the same whether or not an account exists at that address —
  see `QuantumBilling.Accounts.deliver_user_reset_password_instructions/2`.
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
        title="Forgot your password?"
        subtitle="Enter your email and we'll send you a link to set a new one"
      />
      <div class="grid gap-6">
        <.form
          for={@form}
          id="forgot_password_form"
          phx-submit="send"
          phx-change="validate"
          class="space-y-3"
        >
          <.input
            field={@form[:email]}
            type="email"
            placeholder="name@example.com"
            autocomplete="email"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
            class={input_class()}
            error_class="border-red-500"
          />

          <.button phx-disable-with="Sending..." class={primary_button_class()}>
            Send reset link
          </.button>
        </.form>

        <p class="text-center text-sm text-base-content/60">
          Remembered it?
          <.link navigate={~p"/users/log-in"} class="underline underline-offset-4">
            Sign in
          </.link>
        </p>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{"email" => ""}, as: "user"))}
  end

  @impl true
  def handle_event("send", %{"user" => %{"email" => email}}, socket) do
    Accounts.deliver_user_reset_password_instructions(
      email,
      &url(~p"/users/reset-password/#{&1}")
    )

    {:noreply,
     socket
     |> put_flash(
       :info,
       "If an account exists for that email, a password reset link is on its way."
     )
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    {:noreply, assign(socket, form: to_form(user_params, as: "user"))}
  end
end
