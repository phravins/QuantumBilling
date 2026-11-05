defmodule QuantumBilling.Workers.EInvoiceWorker do
  @moduledoc """
  Registers an invoice with the IRP in the background.

  Retries are spread over hours, since IRP outages last hours. Jobs are unique
  per invoice, because a duplicate registration is a compliance problem.
  """
  use QuantumBilling.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: 900, fields: [:worker, :args], states: [:available, :scheduled, :executing]]

  require Logger

  alias QuantumBilling.Invoices

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # 1, 4, 9, 16 minutes.
    trunc(:math.pow(attempt, 2) * 60)
  end

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: %{"invoice_id" => invoice_id}}) do
    case Invoices.get_invoice(invoice_id) do
      nil ->
        Logger.warning("[EInvoiceWorker] invoice #{invoice_id} no longer exists")
        :discard

      %{irn: irn} when is_binary(irn) and irn != "" ->
        # Already registered, by an earlier attempt or by hand.
        :ok

      invoice ->
        case Invoices.generate_einvoice(invoice) do
          {:ok, _invoice} ->
            :ok

          {:error, reason} ->
            {:error, reason_message(reason)}
        end
    end
  end

  def process(%Oban.Job{}), do: :discard

  defp reason_message(reason) when is_binary(reason), do: reason
  defp reason_message(reason), do: inspect(reason)
end
