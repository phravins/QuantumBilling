defmodule QuantumBilling.Workers.TaskReminderWorker do
  @moduledoc """
  Sends the reminders for tasks added by hand, at the time each one asked for.

  `ComplianceReminderWorker` runs once a morning, which is right for GST
  deadlines and wrong for "remind me at 4 pm the day before". This runs every
  quarter of an hour, so a reminder with a time of day arrives within fifteen
  minutes of it. Each run is cheap: one query for open tasks not yet reminded,
  and a reminder is written once — `reminded_at` and the notification's
  `dedupe_key` both see to that.
  """
  use QuantumBilling.Worker, sweep: true, queue: :maintenance, max_attempts: 3

  alias QuantumBilling.Compliance

  @impl QuantumBilling.Worker
  def process(%Oban.Job{}) do
    {:ok, %{reminded: Compliance.remind_due_tasks(DateTime.utc_now())}}
  end
end
