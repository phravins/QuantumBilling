defmodule QuantumBillingWeb.UserLive.SessionConflict do
  @moduledoc """
  "One device at a time": where a sign-in waits while the device already
  signed in decides whether to let it in.

  The visitor is still signed out here and can only give up. When the other
  device allows it, the hidden form posts to
  `UserSessionController.finish_conflict/2`, where the session is written.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.UserLive.AuthComponents

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.SignInRequest
  alias QuantumBilling.Events

  @impl true
  def mount(_params, session, socket) do
    case session["pending_sign_in"] do
      %{"token" => token} when is_binary(token) ->
        # Subscribe before reading, so an answer in between is not missed.
        if connected?(socket), do: Events.subscribe(Accounts.sign_in_request_topic(token))

        socket =
          socket
          |> assign(:page_title, "Waiting for your other device")
          |> assign(:token, token)
          |> assign(:finish, false)
          |> assign(:finish_form, to_form(%{}, as: :conflict))
          |> refresh()

        if socket.assigns.state == :missing do
          {:ok, redirect(socket, to: ~p"/users/log-in")}
        else
          {:ok, socket}
        end

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Please sign in first.")
         |> redirect(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_info({:sign_in_request_answered, _status}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:check_expiry, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  # Reads the request again and shows where it stands.
  defp refresh(socket) do
    request = Accounts.get_sign_in_request(socket.assigns.token)
    state = state(request)

    if connected?(socket) and state in [:waiting, :approved] do
      ms = max(DateTime.diff(request.expires_at, DateTime.utc_now(), :millisecond), 0)
      Process.send_after(self(), :check_expiry, ms + 500)
    end

    socket
    |> assign(:state, state)
    # Only set once connected: the form posts itself when this turns true.
    |> assign(:finish, connected?(socket) and state == :approved)
  end

  defp state(nil), do: :missing

  defp state(%SignInRequest{status: status} = request) do
    case {status, SignInRequest.live?(request)} do
      {"pending", true} -> :waiting
      {"approved", true} -> :approved
      {"denied", _} -> :denied
      _expired_or_cancelled -> :expired
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <Layouts.auth_heading title={title(@state)} subtitle={subtitle(@state)} />

      <div class="grid gap-6">
        <div
          :if={@state == :waiting}
          id="session-conflict-waiting"
          class="flex flex-col items-center gap-3 rounded-xl border border-base-300 bg-base-200/40 px-4 py-6 text-center"
        >
          <span class="relative grid size-11 place-items-center">
            <span class="absolute inset-0 rounded-full bg-primary/15 motion-safe:animate-ping" />
            <span class="relative grid size-11 place-items-center rounded-full bg-primary/15 text-primary">
              <.icon name="hero-device-phone-mobile" class="size-5" />
            </span>
          </span>
          <p class="text-sm text-base-content/70">
            This account is signed in on another device. We've asked that device to let you in.
          </p>
          <p class="text-xs text-base-content/50">This page updates on its own.</p>
        </div>

        <div
          :if={@state == :denied}
          id="session-conflict-denied"
          class="flex items-start gap-3 rounded-xl border border-error/30 bg-error/5 px-4 py-4 text-sm"
        >
          <.icon name="hero-no-symbol" class="mt-0.5 size-5 shrink-0 text-error" />
          <p class="text-base-content/80">The other device chose to stay signed in.</p>
        </div>

        <div
          :if={@state == :expired}
          id="session-conflict-expired"
          class="flex items-start gap-3 rounded-xl border border-warning/30 bg-warning/5 px-4 py-4 text-sm"
        >
          <.icon name="hero-clock" class="mt-0.5 size-5 shrink-0 text-warning" />
          <p class="text-base-content/80">No answer from the other device. Try again later.</p>
        </div>

        <div
          :if={@state == :approved}
          id="session-conflict-approved"
          class="flex items-center justify-center gap-2 text-sm text-base-content/70"
        >
          <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" /> Signing you in…
        </div>

        <.form
          for={@finish_form}
          id="session-conflict-finish"
          action={~p"/users/session-conflict"}
          method="post"
          phx-trigger-action={@finish}
          class="hidden"
        >
        </.form>

        <.link
          id="session-conflict-sign-out"
          href={~p"/users/session-conflict"}
          method="delete"
          class={outline_button_class()}
        >
          Sign out
        </.link>

        <.link
          id="session-conflict-reset-password"
          navigate={~p"/users/forgot-password"}
          class="text-center text-sm text-base-content/60 underline underline-offset-4 hover:text-base-content"
        >
          Lost that device? Reset your password to sign out everywhere.
        </.link>
      </div>
    </Layouts.auth>
    """
  end

  defp title(:denied), do: "Sign-in refused"
  defp title(:expired), do: "No answer"
  defp title(:approved), do: "Allowed"
  defp title(_waiting), do: "Waiting for your other device"

  defp subtitle(:approved), do: "Your other device signed out"
  defp subtitle(_state), do: "Your account can be used on one device at a time"
end
