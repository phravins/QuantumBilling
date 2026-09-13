defmodule QuantumBilling.Workers.RecurringInvoiceWorker do
  @moduledoc """
  Issues the invoices that recurring profiles are due for.

  Two shapes, one worker:

    * with no arguments it is the daily sweep — it finds the due profiles and
      fans out one job per profile, so a single broken profile cannot stop the
      rest from billing;
    * with `%{"profile_id" => id}` it bills that one profile.

  The sweep is what the Cron plugin runs. Cron jobs are inserted by the Oban
  leader, one node at a time, which is the thing a plain `GenServer` timer
  could not do: on two nodes it ran twice and every customer was invoiced
  twice.

  Per-profile jobs are unique over a period of an hour, so a retried sweep, a
  manual run and the scheduled run cannot between them bill the same profile
  three times in a morning.
  """
  use Oban.Worker,
    queue: :recurring,
    max_attempts: 3,
    unique: [
      period: 3_600,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing]
    ]

  require Logger

  alias QuantumBilling.Recurring

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
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

  def perform(%Oban.Job{}) do
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
