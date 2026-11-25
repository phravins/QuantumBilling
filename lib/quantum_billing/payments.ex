defmodule QuantumBilling.Payments do
  @moduledoc "Payment links, UPI QR payloads and Razorpay reconciliation."

  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.RazorpayClient
  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Audit
  alias QuantumBilling.Notifications
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Webhooks
  alias QuantumBillingWeb.Format

  import Ecto.Query, only: [from: 2]

  # A customer who bears the gateway fee pays a little over the total (about
  # 2-3.5% with GST). Anything beyond this is not that, so it is not applied.
  @overpayment_tolerance_percent 5

  @doc """
  The secret that verifies Razorpay webhooks delivered to `business`'s URL:
  `{:ok, secret}`, or `{:error, :not_configured}`.

  Each business's own, so knowing one firm's secret signs nothing for another.
  Only business 1, the one the legacy unslugged URL reaches, falls back to the
  server-wide `RAZORPAY_WEBHOOK_SECRET` while it has none of its own.
  """
  def webhook_secret(%{id: business_id} = business) do
    organization = Repo.with_business(business, &Settings.get_organization/0)

    cond do
      Organization.razorpay_webhook_secret_set?(organization) ->
        {:ok, organization.razorpay_webhook_secret}

      business_id == 1 and present?(System.get_env("RAZORPAY_WEBHOOK_SECRET")) ->
        {:ok, System.get_env("RAZORPAY_WEBHOOK_SECRET")}

      true ->
        {:error, :not_configured}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc """
  `url` if it is safe to link a customer to (`https://`, a host, no credentials), else `nil`.

  Checked where it is used, since it lands in a redirect and an `href`.
  """
  def safe_payment_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        url

      _other ->
        nil
    end
  end

  def safe_payment_url(_url), do: nil

  @doc "Whether the invoice can still be paid at all: not once it is paid, credited or cancelled."
  def open_for_payment?(%Invoice{status: status}),
    do: status not in ["Paid", "Credited", "Cancelled"]

  @doc "Whether Razorpay and UPI can collect this invoice: they take INR only."
  def online_payable?(%Invoice{currency: currency}), do: currency in [nil, "INR"]

  @doc "What to show instead of a payment option for another currency."
  def unavailable_message(%Invoice{currency: currency}),
    do: "Online payment not available for #{currency}"

  @doc """
  Generates a dynamic payment link and UPI QR payload for an invoice.

  Refused with `:already_paid`, `:credited`, `:cancelled` or `:unsupported_currency`.
  """
  def generate_payment_link(%Invoice{} = invoice) do
    cond do
      invoice.status == "Paid" -> {:error, :already_paid}
      invoice.status == "Credited" -> {:error, :credited}
      invoice.status == "Cancelled" -> {:error, :cancelled}
      not online_payable?(invoice) -> {:error, :unsupported_currency}
      true -> create_payment_link(invoice)
    end
  end

  defp create_payment_link(invoice) do
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
  Processes a Razorpay payment webhook and reconciles the invoice.

  A valid signature doesn't prove the payment is for this invoice, so the full
  amount, currency and payment link are checked first. A mismatch is rejected,
  audited and raised with the owner.
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

  # Its link may still be paid; the money has to go back, not into the books.
  defp verify_payment(%Invoice{status: "Cancelled"} = invoice, received, payment_id),
    do: reject_payment(invoice, :invoice_cancelled, received, payment_id)

  # Credit notes already cover it; a payment now is owed back to the client.
  defp verify_payment(%Invoice{status: "Credited"} = invoice, received, payment_id),
    do: reject_payment(invoice, :invoice_credited, received, payment_id)

  # An already-paid invoice is left to reconcile_payment/2, which ignores repeats.
  defp verify_payment(%Invoice{status: "Paid"}, _received, _payment_id), do: :ok

  defp verify_payment(%Invoice{} = invoice, received, payment_id) do
    expected_amount = invoice.grand_total || 0
    expected_currency = invoice.currency || "INR"
    ceiling = expected_amount + div(expected_amount * @overpayment_tolerance_percent, 100)

    cond do
      not is_integer(received.amount) or received.amount < expected_amount or
          received.amount > ceiling ->
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
        expected_amount: invoice.grand_total || 0,
        expected_currency: invoice.currency || "INR",
        received_amount: received.amount,
        received_currency: received.currency,
        payment_link_id: received[:link_id]
      }
    )

    {title, body} = rejection_message(invoice, reason, payment_id || "unknown")

    Notifications.notify(%{
      kind: "payment",
      severity: "error",
      title: title,
      body: body,
      path: "/invoices/#{invoice.id}",
      dedupe_key: "payment_rejected:#{payment_id || "invoice-#{invoice.id}"}"
    })

    {:error, reason}
  end

  defp rejection_message(invoice, :invoice_cancelled, payment_id) do
    {"Payment received for cancelled #{invoice.invoice_number}",
     "Not applied, as the invoice is cancelled. Refund payment #{payment_id} in Razorpay."}
  end

  defp rejection_message(invoice, :invoice_credited, payment_id) do
    {"Payment received for credited #{invoice.invoice_number}",
     "Not applied, as credit notes already cover the invoice. Refund payment #{payment_id} in Razorpay."}
  end

  defp rejection_message(invoice, reason, payment_id) do
    {"Payment for #{invoice.invoice_number} did not match the invoice",
     "Not marked paid (#{reason}). Review payment #{payment_id} in Razorpay."}
  end

  @doc """
  The part of a Razorpay webhook kept in the ledger. Payer details (email, phone, UPI, card, bank) are dropped.
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
  Records a payment made outside the gateway against `invoice`.

  `amount` is paise and must cover the invoice (no partial payments). `reference`
  is stored with an `ext:` prefix. Refused for paid, credited or cancelled invoices.
  """
  def record_payment(%Invoice{} = invoice, reference, amount, audit_opts \\ [])
      when is_binary(reference) and is_integer(amount) do
    cond do
      invoice.status == "Paid" -> {:error, :already_paid}
      invoice.status == "Credited" -> {:error, :credited}
      invoice.status == "Cancelled" -> {:error, :cancelled}
      amount < (invoice.grand_total || 0) -> {:error, :partial_payment}
      true -> reconcile_payment(invoice, "ext:" <> reference, audit_opts)
    end
  end

  @doc """
  Marks an invoice paid and sends the receipt, notification and webhook.

  Already-paid invoices return `{:ok, invoice}` untouched; cancelled ones are
  refused with `:invoice_cancelled`.
  """
  def reconcile_payment(invoice, payment_id, audit_opts \\ [])

  def reconcile_payment(%Invoice{status: "Paid"} = invoice, _payment_id, _audit_opts),
    do: {:ok, invoice}

  def reconcile_payment(%Invoice{status: "Cancelled"}, _payment_id, _audit_opts),
    do: {:error, :invoice_cancelled}

  def reconcile_payment(%Invoice{status: "Credited"}, _payment_id, _audit_opts),
    do: {:error, :invoice_credited}

  def reconcile_payment(%Invoice{} = invoice, payment_id, audit_opts) do
    case mark_paid(invoice, payment_id) do
      {:ok, {:already_paid, current}} ->
        {:ok, current}

      {:ok, updated} ->
        Audit.log_event(
          :payment_received,
          "Invoice",
          updated.id,
          Keyword.take(audit_opts, [:user_id, :api_key_id, :ip_address]) ++
            [
              details: %{
                payment_id: payment_id,
                # Whole units, as older entries in the log hold.
                amount:
                  div(updated.grand_total || 0, QuantumBilling.Currency.unit(updated.currency))
              }
            ]
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
          body: "#{updated.client_name} · #{Format.money(updated.grand_total, updated.currency)}",
          path: "/invoices/#{updated.id}",
          dedupe_key: "payment:#{payment_id || "invoice-#{updated.id}"}"
        })

        Webhooks.publish("invoice.paid", updated.id, %{
          invoice_number: updated.invoice_number,
          invoice_id: updated.id,
          # Whole units (rupees, dinars), as integrations have always received it.
          amount: div(updated.grand_total, QuantumBilling.Currency.unit(updated.currency)),
          payment_id: payment_id,
          client_name: updated.client_name
        })

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The row is locked and its status read again, so an invoice cancelled since
  # `invoice` was loaded is not marked paid. cancel_invoice/3 takes the same lock.
  defp mark_paid(%Invoice{id: id} = invoice, payment_id) do
    Repo.transaction(fn ->
      case Repo.one(from(i in Invoice, where: i.id == ^id, lock: "FOR UPDATE", select: i.status)) do
        nil ->
          Repo.rollback(:invoice_not_found)

        "Paid" ->
          {:already_paid, Repo.get!(Invoice, id)}

        "Cancelled" ->
          Repo.rollback(:invoice_cancelled)

        "Credited" ->
          Repo.rollback(:invoice_credited)

        _payable ->
          invoice
          |> Ecto.Changeset.change(%{status: "Paid", razorpay_payment_id: payment_id})
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end
end
