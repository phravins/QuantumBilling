defmodule QuantumBilling.Workers.PaymentLinkCancelWorker do
  @moduledoc """
  Cancels a cancelled invoice's Razorpay payment link, so the customer can no
  longer pay it.

  Queued by `QuantumBilling.Invoices.cancel_invoice/3`. Retried, since a
  Razorpay outage must not leave the link open. The link id is kept on the
  invoice so a payment that still arrives is matched and refused. If the link
  cannot be cancelled, the owner is told to cancel it in Razorpay.
  """
  use QuantumBilling.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: 900, fields: [:worker, :args], states: [:available, :scheduled, :executing]]

  require Logger

  alias QuantumBilling.Audit
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Notifications
  alias QuantumBilling.Payments.RazorpayClient
  alias QuantumBilling.Repo

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # 1, 4, 9, 16 minutes.
    trunc(:math.pow(attempt, 2) * 60)
  end

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: %{"invoice_id" => invoice_id}} = job) do
    case Repo.get(Invoice, invoice_id) do
      %Invoice{status: "Cancelled", razorpay_payment_link_id: link_id} = invoice
      when is_binary(link_id) and link_id != "" ->
        cancel(invoice, link_id, job)

      _gone_or_nothing_to_cancel ->
        :discard
    end
  end

  def process(%Oban.Job{}), do: :discard

  defp cancel(invoice, link_id, job) do
    case RazorpayClient.cancel_payment_link(link_id) do
      :ok ->
        {:ok, updated} =
          invoice |> Ecto.Changeset.change(razorpay_payment_url: nil) |> Repo.update()

        Audit.log_event(:payment_link_cancelled, "Invoice", updated.id,
          details: %{"number" => updated.invoice_number, "payment_link_id" => link_id}
        )

        Invoices.broadcast_change(updated)
        :ok

      {:error, {:refused, description}} ->
        warn_owner(invoice, description)
        {:discard, description}

      {:error, reason} ->
        if job.attempt >= job.max_attempts, do: warn_owner(invoice, reason)
        {:error, reason}
    end
  end

  defp warn_owner(invoice, reason) do
    Logger.warning(
      "[PaymentLinkCancel] link for invoice #{invoice.id} not cancelled: #{inspect(reason)}"
    )

    Notifications.notify(%{
      kind: "payment",
      severity: "warning",
      title: "Couldn't cancel the payment link for #{invoice.invoice_number}",
      body: "Razorpay said: #{reason}. Cancel the link in the Razorpay dashboard.",
      path: "/invoices/#{invoice.id}",
      dedupe_key: "payment_link_cancel:#{invoice.id}"
    })
  end
end
