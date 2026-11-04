defmodule QuantumBillingWeb.BusinessReadyLive do
  @moduledoc """
  Step two of choosing a company: the confirmation after
  `QuantumBillingWeb.BusinessController.switch/2` has opened it.

  Shows which company is now open and the user's role there, then moves on to
  the dashboard by itself after a moment. The timer only starts once the socket
  is connected, so the static render never redirects; the button goes straight
  there for anyone who does not want to wait.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.Illustrations, only: [success: 1]

  alias QuantumBilling.Accounts.Scope

  # Kept in step with `.qb-ready-countdown` in app.css, which draws the bar.
  @delay 2_500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :continue, @delay)

    {:ok, assign(socket, :page_title, "You're in")}
  end

  @impl true
  def handle_info(:continue, socket) do
    {:noreply, push_navigate(socket, to: ~p"/dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.focus flash={@flash} current_scope={@current_scope} step={2} steps={2}>
      <div
        id="business-ready"
        class="qb-rise my-auto flex w-full max-w-md flex-col items-center text-center"
      >
        <.success class="qb-pop-in h-48 w-auto sm:h-56" />

        <p class="mt-6 text-sm font-medium text-base-content/55">
          Company opened
        </p>
        <h1 id="ready-title" class="mt-1.5 text-2xl font-semibold tracking-tight sm:text-3xl">
          You're in {@current_scope.business.name}
        </h1>
        <p id="ready-role" class="mt-2 text-sm text-base-content/60">
          {role_line(@current_scope)}
        </p>

        <div
          class="mt-8 h-1 w-48 overflow-hidden rounded-full bg-base-content/10"
          aria-hidden="true"
        >
          <div class="qb-ready-countdown h-full w-full rounded-full bg-base-content"></div>
        </div>
        <p class="mt-2 text-xs text-base-content/45">Taking you to your dashboard…</p>

        <.link
          navigate={~p"/dashboard"}
          id="ready-continue"
          class={[Layouts.focus_next_class(), "mt-8"]}
        >
          Go to dashboard <.icon name="hero-arrow-right-mini" class="size-4" />
        </.link>
      </div>
    </Layouts.focus>
    """
  end

  defp role_line(scope) do
    if Scope.owner?(scope),
      do: "You own this company: every setting and record is yours to manage.",
      else: "You are working here as staff."
  end
end
