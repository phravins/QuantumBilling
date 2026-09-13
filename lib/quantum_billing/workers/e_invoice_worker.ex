defmodule QuantumBilling.Workers.EInvoiceWorker do
  @moduledoc """
  Registers an invoice with the Invoice Registration Portal.

  The IRP is a government service reached over the public internet, and it is
  slow and occasionally unavailable. Doing this inside the click that asked for
  it meant a LiveView waiting on it, and a failure that left the invoice marked
  `"E-Invoice Failed"` with nothing that would ever try again.

  Attempts are spread over hours rather than minutes: an IRP outage is measured
  in hours, and hammering it during one is both useless and rude.

  Uniqueness is enforced on the invoice: an impatient second click, or a
  retried request, must not attempt to register the same invoice twice. A
  duplicate registration is a compliance problem, not a harmless repeat.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: 900, fields: [:worker, :args], states: [:available, :scheduled, :executing]]

  require Logger

  alias QuantumBilling.Invoices

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # 1, 4, 9, 16 minutes — quadratic, so a portal outage is waited out rather
    # than polled.
    trunc(:math.pow(attempt, 2) * 60)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invoice_id" => invoice_id}}) do
    case Invoices.get_invoice(invoice_id) do
      nil ->
        Logger.warning("[EInvoiceWorker] invoice #{invoice_id} no longer exists")
        :discard

      %{irn: irn} when is_binary(irn) and irn != "" ->
        # Already registered — by an earlier attempt whose reply was lost, or
        # by hand. Asking again would be a duplicate registration.
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

  def perform(%Oban.Job{}), do: :discard

  defp reason_message(reason) when is_binary(reason), do: reason
  defp reason_message(reason), do: inspect(reason)
end
