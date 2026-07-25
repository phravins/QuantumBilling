defmodule QuantumBillingWeb.UserLive.Confirmation do
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="space-y-6">
        <div class="space-y-2 text-center">
          <h1 class="text-3xl font-bold tracking-tight">Welcome</h1>
          <p class="text-base-content/60">{@user.email}</p>
        </div>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="Confirming..."
            class="btn btn-neutral w-full"
          >
            Confirm and stay logged in
          </.button>
          <.button phx-disable-with="Confirming..." class="btn btn-soft w-full mt-2">
            Confirm and log in only this time
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with="Logging in..." class="btn btn-neutral w-full">
              Log in
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Logging in..."
              class="btn btn-neutral w-full"
            >
              Keep me logged in on this device
            </.button>
            <.button phx-disable-with="Logging in..." class="btn btn-soft w-full mt-2">
              Log me in only this time
            </.button>
          <% end %>
        </.form>

        <p :if={!@user.confirmed_at} class="alert alert-outline text-sm">
          Tip: If you prefer passwords, you can enable them in the user settings.
        </p>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
