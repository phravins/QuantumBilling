defmodule QuantumBilling.Payments do
  @moduledoc """
  Context module for Payment Links, UPI QR generation, and Auto-Reconciliation.
  """

  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.RazorpayClient
  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Audit
  alias QuantumBilling.Notifications
  alias QuantumBilling.Repo
  alias QuantumBilling.Webhooks
  alias QuantumBillingWeb.Format

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

  A valid signature proves the event came from Razorpay, not that it pays this
  invoice. So the payment is checked against the invoice before anything is
  marked paid: the full amount, in the invoice's currency, and — for a payment
  link — the link that was issued for it. A payment that fails any of these is
  rejected, audited and raised with the owner, and the invoice stays unpaid.
  """
  def process_razorpay_webhook(%{"event" => "payment_link.paid", "payload" => payload}) do
    payment_link = get_in(payload, ["payment_link", "entity"]) || %{}
    payment = get_in(payload, ["payment", "entity"]) || %{}

    ref_id = payment_link["reference_id"]
    payment_id = payment["id"] || payment_link["id"]

    received = %{
      amount: payment_link["amount_paid"] || payment["amount"],
      currency: payment_link["currency"] || payment["currency"],
      link_id: payment_link["id"]
    }

    with %Invoice{} = invoice <- ref_id && invoice_for_payment(ref_id),
         :ok <- verify_payment(invoice, received, payment_id) do
      reconcile_payment(invoice, payment_id)
    else
      nil -> {:error, :invoice_not_found}
      {:error, _reason} = error -> error
    end
  end

  def process_razorpay_webhook(%{"event" => "payment.captured", "payload" => payload}) do
    payment = get_in(payload, ["payment", "entity"]) || %{}
    received = %{amount: payment["amount"], currency: payment["currency"]}

    with number when is_binary(number) <- captured_invoice_number(payment),
         %Invoice{} = invoice <- invoice_for_payment(number),
         :ok <- verify_payment(invoice, received, payment["id"]) do
      reconcile_payment(invoice, payment["id"])
    else
      {:error, _reason} = error -> error
      _not_found -> {:error, :invoice_not_found}
    end
  end

  def process_razorpay_webhook(_other), do: {:ok, :ignored}

  # The notes set on the payment link name the invoice exactly; the description
  # is free text, so it is only a fallback, and the amount check still applies.
  defp captured_invoice_number(payment) do
    case payment["notes"] do
      %{"invoice_number" => number} when is_binary(number) and number != "" ->
        number

      _no_notes ->
        case Regex.run(~r/INV-\d+/, payment["description"] || "") do
          [number] -> number
          _ -> nil
        end
    end
  end

  # An already-paid invoice is left to reconcile_payment/2, which ignores repeats.
  defp verify_payment(%Invoice{status: "Paid"}, _received, _payment_id), do: :ok

  defp verify_payment(%Invoice{} = invoice, received, payment_id) do
    expected_amount = (invoice.grand_total || 0) * 100
    expected_currency = invoice.currency || "INR"

    cond do
      not is_integer(received.amount) or received.amount < expected_amount ->
        reject_payment(invoice, :amount_mismatch, received, payment_id)

      received.currency != expected_currency ->
        reject_payment(invoice, :currency_mismatch, received, payment_id)

      invoice.razorpay_payment_link_id not in [nil, ""] and
        Map.has_key?(received, :link_id) and
          received.link_id != invoice.razorpay_payment_link_id ->
        reject_payment(invoice, :unknown_payment_link, received, payment_id)

      true ->
        :ok
    end
  end

  defp reject_payment(%Invoice{} = invoice, reason, received, payment_id) do
    Audit.log_event(:payment_rejected, "Invoice", invoice.id,
      details: %{
        reason: reason,
        payment_id: payment_id,
        expected_amount: (invoice.grand_total || 0) * 100,
        expected_currency: invoice.currency || "INR",
        received_amount: received.amount,
        received_currency: received.currency,
        payment_link_id: received[:link_id]
      }
    )

    Notifications.notify(%{
      kind: "payment",
      severity: "error",
      title: "Payment for #{invoice.invoice_number} did not match the invoice",
      body: "Not marked paid (#{reason}). Review payment #{payment_id || "unknown"} in Razorpay.",
      path: "/invoices/#{invoice.id}",
      dedupe_key: "payment_rejected:#{payment_id || "invoice-#{invoice.id}"}"
    })

    {:error, reason}
  end

  @doc """
  The part of a Razorpay webhook worth keeping in the ledger.

  Enough to investigate a disputed payment — which event, which payment and
  link, how much, in what currency, by what method — and nothing about the
  payer: email, phone, UPI ID, card and bank details are dropped before the
  event is stored, rather than being encrypted and kept for no reason.
  """
  def webhook_record(params) when is_map(params) do
    payload = if is_map(params["payload"]), do: params["payload"], else: %{}

    %{
      "event" => params["event"],
      "payment_link" =>
        payload
        |> entity("payment_link")
        |> Map.take(~w(id reference_id amount amount_paid currency status)),
      "payment" =>
        payload
        |> entity("payment")
        |> Map.take(~w(id order_id amount currency status method captured))
        |> put_invoice_note(entity(payload, "payment"))
    }
    |> Map.reject(fn {_key, value} -> value in [nil, %{}] end)
  end

  def webhook_record(_params), do: %{}

  defp entity(payload, name) do
    case get_in(payload, [name, "entity"]) do
      %{} = entity -> entity
      _missing -> %{}
    end
  end

  # Notes are free-form and may carry anything; only the invoice reference is ours.
  defp put_invoice_note(kept, %{"notes" => %{"invoice_number" => number}})
       when is_binary(number),
       do: Map.put(kept, "notes", %{"invoice_number" => number})

  defp put_invoice_note(kept, _payment), do: kept

  # Binned invoices included: a payment link may be paid after the invoice was binned.
  defp invoice_for_payment(invoice_number) do
    Invoices.get_invoice_by_number(invoice_number, include_binned: true)
  end

  @doc """
  Marks an invoice paid and tells everyone who needs to know.

  Already-paid invoices are left alone and reported as `{:ok, invoice}`: a
  webhook redelivery, a manual reconciliation and a second payment
  notification all end up here, and none of them should re-stamp the invoice,
  re-audit the payment or send the customer another receipt. The webhook ledger
  catches most repeats; this catches the rest.
  """
  def reconcile_payment(%Invoice{status: "Paid"} = invoice, _payment_id), do: {:ok, invoice}

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

        # Queued: this runs inside a timed webhook request.
        if updated.client_email && updated.client_email != "" do
          InvoiceNotifier.deliver_invoice_pdf_async(updated.client_email, updated,
            kind: "payment_receipt"
          )
        end

        Invoices.broadcast_change(updated)

        # Not gated. Keyed on the payment id so a redelivered webhook adds nothing.
        Notifications.notify(%{
          kind: "payment",
          severity: "success",
          title: "Payment received for #{updated.invoice_number}",
          body: "#{updated.client_name} · #{Format.rupees(updated.grand_total)}",
          path: "/invoices/#{updated.id}",
          dedupe_key: "payment:#{payment_id || "invoice-#{updated.id}"}"
        })

        Webhooks.dispatch("invoice.paid", %{
          invoice_number: updated.invoice_number,
          invoice_id: updated.id,
          amount: updated.grand_total,
          payment_id: payment_id,
          client_name: updated.client_name
        })

        {:ok, updated}

      {:error, cs} ->
        {:error, cs}
    end
  end
end
