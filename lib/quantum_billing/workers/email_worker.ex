defmodule QuantumBilling.Workers.EmailWorker do
  @moduledoc """
  Sends one queued message and records each attempt in the delivery ledger.

  Five attempts with exponential backoff (about 15 minutes). Permanent
  failures (bad address, missing invoice or quotation) return `:discard` instead of retrying.
  """
  use QuantumBilling.Worker, queue: :mailers, max_attempts: 5

  require Logger

  alias QuantumBilling.Accounts
  alias QuantumBilling.Compliance.ReminderEmail
  alias QuantumBilling.Compliance.Task
  alias QuantumBilling.EWayBillNotifier
  alias QuantumBilling.EWayBills
  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Invoices
  alias QuantumBilling.Mail
  alias QuantumBilling.QuotationNotifier
  alias QuantumBilling.Quotations
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: %{"delivery_id" => delivery_id}} = job) do
    case Mail.get_delivery(delivery_id) do
      nil ->
        Logger.warning("[EmailWorker] delivery #{delivery_id} no longer exists")
        :discard

      delivery ->
        deliver(delivery, job)
    end
  end

  @impl QuantumBilling.Worker
  def process(%Oban.Job{
        args: %{
          "action" => "deliver_reset_password_instructions",
          "email" => email,
          "reset_url_template" => reset_url_template
        }
      })
      when is_binary(email) and is_binary(reset_url_template) do
    case Accounts.deliver_reset_password_email_now(email, reset_url_template) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def process(%Oban.Job{}), do: :discard
end
