defmodule QuantumBillingWeb.UserLive.TwoFactorChallenge do
  @moduledoc """
  The second step of signing in: the six-digit code from an authenticator app,
  or one of the recovery codes issued at enrolment.

  The form posts straight to `UserSessionController.verify_two_factor/2` rather
  than being handled here. That keeps a single authoritative check: a recovery
  code is single use, and verifying it both here and in the controller would
  consume it twice. It also means the session cookie is written by a normal
  request, which a LiveView cannot do.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.UserLive.AuthComponents

  @impl true
  def mount(_params, session, socket) do
    # Only a sign-in already past the password step may see this page. Anything
    # else is sent back to the start rather than shown a code box that could
    # never work.
    case session["pending_two_factor"] do
      %{"user_id" => _} ->
        {:ok,
         socket
         |> assign(:page_title, "Two-factor authentication")
         |> assign(:recovery?, false)}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Please sign in first.")
         |> redirect(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("use_recovery", _params, socket) do
    {:noreply, assign(socket, :recovery?, true)}
  end

  def handle_event("use_authenticator", _params, socket) do
    {:noreply, assign(socket, :recovery?, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <Layouts.auth_heading
        title="Two-factor authentication"
        subtitle={
          if @recovery?,
            do: "Enter one of the recovery codes you saved when you set this up",
            else: "Enter the 6-digit code from your authenticator app"
        }
      />
      <div class="grid gap-6">
        <.form for={%{}} action={~p"/users/two-factor"} method="post" class="space-y-3">
          <input
            :if={not @recovery?}
            type="text"
            name="user[code]"
            inputmode="numeric"
            pattern="[0-9]*"
            maxlength="6"
            autocomplete="one-time-code"
            placeholder="000000"
            required
            autofocus
            class={[input_class(), "text-center text-lg tracking-[0.4em]"]}
          />
          <input
            :if={@recovery?}
            type="text"
            name="user[code]"
            autocomplete="off"
            spellcheck="false"
            placeholder="Recovery code"
            required
            autofocus
            class={[input_class(), "text-center tracking-widest uppercase"]}
          /> <button type="submit" class={primary_button_class()}>Verify</button>
        </.form>
        
        <button
          :if={not @recovery?}
          type="button"
          phx-click="use_recovery"
          class="text-center text-sm text-base-content/60 underline underline-offset-4 hover:text-base-content"
        >
          Lost your device? Use a recovery code
        </button>
        
        <button
          :if={@recovery?}
          type="button"
          phx-click="use_authenticator"
          class="text-center text-sm text-base-content/60 underline underline-offset-4 hover:text-base-content"
        >
          Use your authenticator app instead
        </button>
        
        <.link
          href={~p"/users/log-out"}
          method="delete"
          class="text-center text-sm text-base-content/60 underline underline-offset-4 hover:text-base-content"
        >
          Cancel and sign in as someone else
        </.link>
      </div>
    </Layouts.auth>
    """
  end
end
