defmodule QuantumBilling.Workers.EmailWorker do
  @moduledoc """
  Sends one queued message, and records what happened.

  Mail is the part of this application most likely to fail for reasons that
  have nothing to do with it: a relay rate-limits, a certificate expires, a DNS
  record changes. None of that should lose an invoice or stall the page that
  asked for it, so delivery runs here — retried with exponential backoff, with
  every attempt written to the delivery ledger.

  ## Retries

  Five attempts over roughly a quarter of an hour of backoff. Failures that
  cannot improve by being repeated — a recipient that is not an address, an
  invoice that no longer exists — are **not** retried: they return `:discard`,
  so a permanent problem is not disguised as a slow one.
  """
  use Oban.Worker, queue: :mailers, max_attempts: 5

  require Logger

  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Invoices
  alias QuantumBilling.Mail
  alias QuantumBilling.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}} = job) do
    case Mail.get_delivery(delivery_id) do
      nil ->
        # The ledger row is the job's whole subject. If it is gone, the job is
        # about nothing and retrying cannot change that.
        Logger.warning("[EmailWorker] delivery #{delivery_id} no longer exists")
        :discard

      delivery ->
        deliver(delivery, job)
    end
  end

  def perform(%Oban.Job{}), do: :discard

  defp deliver(delivery, job) do
    case build(delivery, job.args) do
      {:ok, email} ->
        case Mail.deliver(email, Settings.get_organization()) do
          {:ok, _metadata} ->
            {:ok, _} = Mail.mark_sent(delivery)
            :ok

          {:error, message} ->
            record_failure(delivery, job, message)
        end

      {:error, :permanent, message} ->
        _ = Mail.mark_failed(delivery, message, true)
        Logger.error("[EmailWorker] delivery #{delivery.id} discarded: #{message}")
        :discard

      {:error, message} ->
        record_failure(delivery, job, message)
    end
  end

  # Oban decides whether another attempt is coming; the ledger follows that
  # decision rather than guessing, so "failed" in the UI means Oban has given
  # up too.
  defp record_failure(delivery, %Oban.Job{attempt: attempt, max_attempts: max}, message) do
    final? = attempt >= max
    _ = Mail.mark_failed(delivery, message, final?)

    Logger.warning(
      "[EmailWorker] delivery #{delivery.id} attempt #{attempt}/#{max} failed: #{message}"
    )

    {:error, message}
  end

  defp build(delivery, %{"invoice_id" => invoice_id}) when not is_nil(invoice_id) do
    case Invoices.get_invoice(invoice_id) do
      nil ->
        {:error, :permanent, "invoice #{invoice_id} no longer exists"}

      invoice ->
        case InvoiceNotifier.build_email(delivery.to_email, invoice) do
          {:ok, email} -> {:ok, email}
          {:error, message} -> {:error, message}
        end
    end
  end

  defp build(delivery, _args) do
    {:error, :permanent, "delivery #{delivery.id} has no invoice to render"}
  end
end
