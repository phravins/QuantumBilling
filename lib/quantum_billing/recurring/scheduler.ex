defmodule QuantumBilling.Recurring.Scheduler do
  @moduledoc """
  Background GenServer OTP worker that periodically executes due recurring invoice profiles.
  """
  use GenServer
  require Logger

  alias QuantumBilling.Recurring

  # Check every 12 hours
  @interval :timer.hours(12)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Application.get_env(:quantum_billing, :start_scheduler, true) do
      Process.send_after(self(), :check_due_profiles, 5000)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:check_due_profiles, state) do
    Logger.info("[Recurring.Scheduler] Checking for due recurring invoice profiles...")

    try do
      results = Recurring.process_due_profiles()
      processed_count = length(results)

      if processed_count > 0 do
        Logger.info("[Recurring.Scheduler] Processed #{processed_count} recurring invoice(s).")
      end
    rescue
      e ->
        Logger.error(
          "[Recurring.Scheduler] Error processing recurring profiles: #{Exception.message(e)}"
        )
    end

    # Schedule next check
    Process.send_after(self(), :check_due_profiles, @interval)
    {:noreply, state}
  end
end
