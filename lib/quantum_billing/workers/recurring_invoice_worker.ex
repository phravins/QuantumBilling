defmodule QuantumBilling.Workers.RecurringInvoiceWorker do
  @moduledoc """
  Issues invoices for due recurring profiles.

  With no args it is the daily Cron sweep (per business, Oban leader only),
  fanning out one job per due profile. With `%{"profile_id" => id}` it bills
  that profile. Profile jobs are unique for an hour, so no profile is billed twice.
  """
  use QuantumBilling.Worker,
    sweep: true,
    queue: :recurring,
    max_attempts: 3,
    unique: [
      period: 3_600,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing]
    ]

  require Logger

  alias QuantumBilling.Recurring

  @impl QuantumBilling.Worker
  def sweep?(args), do: not Map.has_key?(args, "profile_id")

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    case Recurring.get_profile(profile_id) do
      nil ->
        Logger.warning("[RecurringInvoiceWorker] profile #{profile_id} no longer exists")
        :discard

      profile ->
        case Recurring.process_profile(profile) do
          {:ok, invoice} -> {:ok, %{invoice_id: invoice.id, status: "generated"}}
          {:skip, reason} -> {:ok, %{status: "skipped", reason: to_string(reason)}}
          {:error, reason} -> {:error, describe(reason)}
        end
    end
  end

  def process(%Oban.Job{}) do
    queued = Recurring.enqueue_due_profiles()

    if queued > 0 do
      Logger.info("[RecurringInvoiceWorker] queued #{queued} due profile(s)")
    end

    {:ok, %{processed_count: queued}}
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> inspect()
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
