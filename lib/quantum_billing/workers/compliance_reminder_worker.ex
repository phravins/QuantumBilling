defmodule QuantumBilling.Workers.ComplianceReminderWorker do
  @moduledoc """
  Puts GST filing deadlines in the notification feed before they pass.

  Each obligation is announced once, via a `dedupe_key` of obligation and due
  date; overdue ones are marked `error`. Filings aren't recorded yet, so a
  return already filed is still reminded about. Hand-added tasks are always
  reminded, with their own lead time; timed ones go to `TaskReminderWorker`.
  """
  use QuantumBilling.Worker, sweep: true, queue: :maintenance, max_attempts: 3

  require Logger

  alias QuantumBilling.Compliance
  alias QuantumBilling.Notifications
  alias QuantumBilling.Settings

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: args}) do
    organization = Settings.get_organization()

    Compliance.remind_due_tasks(now(args))

    if organization.notify_filing_reminders == false do
      {:ok, :disabled}
    else
      {:ok, %{reminded: remind(organization, today(args))}}
    end
  end

  @doc "Writes a reminder for every obligation inside the lead window and returns the count."
  def remind(organization, %Date{} = today) do
    lead = organization.reminder_lead_days || 7

    written =
      today
      |> Compliance.tracked_obligations(organization)
      |> Enum.reject(&(&1.status == "Filed"))
      |> Enum.map(&Map.put(&1, :days_until, Date.diff(&1.due_date, today)))
      |> Enum.filter(&(&1.days_until <= lead))
      |> Enum.map(&announce/1)
      |> Enum.count(&match?({:ok, %{}}, &1))

    if written > 0 do
      Logger.info("[ComplianceReminderWorker] wrote #{written} filing reminders")
    end

    written
  end

  # {:ok, :duplicate} is not counted.
  defp announce(obligation) do
    Notifications.notify(%{
      kind: "compliance",
      severity: if(obligation.days_until < 0, do: "error", else: "warning"),
      title: title(obligation),
      body: "#{obligation.subtitle} · due #{Calendar.strftime(obligation.due_date, "%d %b %Y")}",
      path: "/compliance",
      dedupe_key: "compliance:#{obligation.type}:#{obligation.period_key}:#{obligation.due_date}"
    })
  end

  defp title(%{days_until: days} = obligation) when days < 0 do
    "#{obligation.type} for #{obligation.period_label} is overdue"
  end

  defp title(%{days_until: 0} = obligation) do
    "#{obligation.type} for #{obligation.period_label} is due today"
  end

  defp title(%{days_until: 1} = obligation) do
    "#{obligation.type} for #{obligation.period_label} is due tomorrow"
  end

  defp title(obligation) do
    "#{obligation.type} for #{obligation.period_label} is due in #{obligation.days_until} days"
  end

  defp today(%{"today" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      _unparseable -> Date.utc_today()
    end
  end

  defp today(_args), do: Date.utc_today()

  # A fixed day in a test means the whole of it; otherwise the clock decides,
  # so a task reminding at 4 pm is not reminded at this morning's run.
  defp now(%{"today" => _date} = args), do: today(args)
  defp now(_args), do: DateTime.utc_now()
end
