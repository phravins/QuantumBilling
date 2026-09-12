defmodule QuantumBilling.Payments do
  @moduledoc """
  Context module for Payment Links, UPI QR generation, and Auto-Reconciliation.
  """

  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.RazorpayClient
  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Audit
  alias QuantumBilling.Repo

  @doc """
  Generates a dynamic payment link and UPI QR payload for an invoice.
  """
  def generate_payment_link(%Invoice{} = invoice) do
    case RazorpayClient.create_payment_link(invoice) do
      {:ok, %{link_id: link_id, short_url: url}} ->
        changeset =
          Ecto.Changeset.change(invoice, %{
            razorpay_payment_link_id: link_id,
            razorpay_payment_url: url
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            Audit.log_event(:generate_payment_link, "Invoice", updated.id,
              details: %{payment_link: url}
            )

            {:ok, updated}

          {:error, cs} ->
            {:error, cs}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Processes a Razorpay payment webhook payload and reconciles the invoice.
  """
  def process_razorpay_webhook(%{"event" => "payment_link.paid", "payload" => payload}) do
    payment_link = get_in(payload, ["payment_link", "entity"]) || %{}
    payment = get_in(payload, ["payment", "entity"]) || %{}

    ref_id = payment_link["reference_id"]
    payment_id = payment["id"] || payment_link["id"]

    invoice = if ref_id, do: Invoices.get_invoice_by_number(ref_id)

    if invoice do
      reconcile_payment(invoice, payment_id)
    else
      {:error, :invoice_not_found}
    end
  end

  def process_razorpay_webhook(%{"event" => "payment.captured", "payload" => payload}) do
    payment = get_in(payload, ["payment", "entity"]) || %{}
    description = payment["description"] || ""

    invoice_number =
      case Regex.run(~r/INV-\d+/, description) do
        [inv_num] -> inv_num
        _ -> nil
      end

    invoice = if invoice_number, do: Invoices.get_invoice_by_number(invoice_number)

    if invoice do
      reconcile_payment(invoice, payment["id"])
    else
      {:error, :invoice_not_found}
    end
  end

  def process_razorpay_webhook(_other), do: {:ok, :ignored}

  def reconcile_payment(%Invoice{} = invoice, payment_id) do
    changeset =
      Ecto.Changeset.change(invoice, %{
        status: "Paid",
        razorpay_payment_id: payment_id
      })

    case Repo.update(changeset) do
      {:ok, updated} ->
        Audit.log_event(:payment_received, "Invoice", updated.id,
          details: %{
            payment_id: payment_id,
            amount: updated.grand_total
          }
        )

        if updated.client_email && updated.client_email != "" do
          InvoiceNotifier.deliver_invoice_pdf(updated.client_email, updated)
        end

        Invoices.broadcast_change(updated)
        {:ok, updated}

      {:error, cs} ->
        {:error, cs}
    end
  end
end
