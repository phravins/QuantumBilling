defmodule QuantumBilling.Workers.RecurringInvoiceWorker do
  @moduledoc """
  Oban worker for executing due recurring billing profiles reliably.
  """
  use Oban.Worker, queue: :recurring, max_attempts: 3

  alias QuantumBilling.Recurring

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    profile = Recurring.get_profile!(profile_id)

    case Recurring.process_profile(profile) do
      {:ok, invoice} ->
        {:ok, %{invoice_id: invoice.id, status: "generated"}}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def perform(%Oban.Job{}) do
    results = Recurring.process_due_profiles()
    {:ok, %{processed_count: length(results)}}
  end
end
