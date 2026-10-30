defmodule QuantumBilling.Workers.CalendarSyncWorker do
  @moduledoc """
  Sends a business's tasks and GST deadlines to its connected calendars.

  Queued whenever a task changes, and swept daily so that deadlines keep arriving
  and passing with no one touching anything. Saving several tasks in a minute
  makes one job, not several.
  """
  use QuantumBilling.Worker,
    sweep: true,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :retryable]]

  alias QuantumBilling.Calendars

  @impl QuantumBilling.Worker
  def process(%Oban.Job{}), do: Calendars.sync_all()
end
