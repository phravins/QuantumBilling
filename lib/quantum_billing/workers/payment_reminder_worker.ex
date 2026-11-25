defmodule QuantumBilling.Workers.PaymentReminderWorker do
  use QuantumBilling.Worker,
    sweep: true,
    queue: :maintenance,
    max_attempts: 3

  import Ecto.Query

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.PaymentReminder
  alias QuantumBilling.Payments.PaymentReminderNotifier
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: args}) do
    organization = Settings.get_organization()

    if organization.payment_reminders_enabled do
      today = today(args)
      days = organization.payment_reminder_days || [-3, 0, 7]

      {:ok, %{queued: queue_reminders(today, days)}}
    else
      {:ok, %{queued: 0, disabled: true}}
    end
  end

  defp queue_reminders(today, days) do
    Enum.reduce(days, 0, fn step, count ->
      due_date = Date.add(today, -step)

      invoices =
        Repo.all(
          from i in Invoice,
            join: c in Client,
            on: c.id == i.client_id,
            where:
              is_nil(i.deleted_at) and
                i.due_date == ^due_date and
                i.status not in ["Draft", "Paid", "Cancelled"] and
                c.reminders_opt_out == false and
                not is_nil(i.client_email) and
                i.client_email != "",
            select: i
        )

      count + Enum.count(invoices, &queue_one(&1, step))
    end)
  end

  defp queue_one(invoice, step) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case %PaymentReminder{}
         |> PaymentReminder.changeset(%{
           invoice_id: invoice.id,
           step: step,
           sent_at: now
         })
         |> Repo.insert() do
      {:ok, reminder} ->
        case PaymentReminderNotifier.deliver_async(invoice, step) do
          {:ok, _delivery} ->
            true

          {:error, _reason} ->
            Repo.delete(reminder)
            false
        end

      {:error, _changeset} ->
        false
    end
  end

  defp today(%{"today" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      _ -> Date.utc_today()
    end
  end

  defp today(_args), do: Date.utc_today()
end
