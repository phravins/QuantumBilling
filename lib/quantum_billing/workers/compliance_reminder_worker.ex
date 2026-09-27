defmodule QuantumBilling.Workers.ComplianceReminderWorker do
  @moduledoc """
  Puts GST filing deadlines in the notification feed before they pass.

  ## Why this exists

  `organization_settings.notify_filing_reminders` and `reminder_lead_days` were
  both saved by the notifications form and read by nothing — the last two of the
  four switches on that panel with nothing behind them. The Compliance page has
  always known these dates; it just required somebody to go and look at it,
  which is precisely what does not happen on the day a return is due.

  ## What it sends, and what it does not

  One line per obligation, once. The `dedupe_key` carries the obligation and its
  due date, so the same GSTR-3B deadline produces exactly one notification no
  matter how many mornings this runs while it is still open. A feed that
  repeated the same reminder daily would be a feed people stop reading, and the
  Compliance page is where somebody goes to see the *standing* position.

  Overdue obligations are included, and marked `error` rather than `warning` —
  a return that is late is the one worth interrupting somebody about. They are
  still only announced once, on the first run after the due date passes, for the
  same reason.

  ## Dates, not filings

  `Compliance.filings/0` is still empty, so every obligation resolves to
  `"Pending"` or `"Overdue"` on the calendar alone. That means a return already
  filed at the GST portal will still be reminded about here. Stating it plainly
  rather than hiding it: the reminder is honest about being a deadline, not a
  status, and it stops being a nuisance the moment filing records land.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias QuantumBilling.Compliance
  alias QuantumBilling.Notifications
  alias QuantumBilling.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    organization = Settings.get_organization()

    if organization.notify_filing_reminders == false do
      {:ok, :disabled}
    else
      {:ok, %{reminded: remind(organization, today(args))}}
    end
  end

  @doc """
  Writes a reminder for every obligation inside the lead window.

  Returns how many were written. Public so a test can call it with a fixed date
  rather than waiting for the clock.
  """
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

  # `{:ok, :duplicate}` from a day this obligation was already announced is a
  # success, not a failure — it is the whole point of the dedupe key — so it is
  # simply not counted.
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

  # An explicit date in the job args, so a test does not have to travel in time.
  defp today(%{"today" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      _unparseable -> Date.utc_today()
    end
  end

  defp today(_args), do: Date.utc_today()
end
