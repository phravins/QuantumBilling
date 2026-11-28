defmodule QuantumBilling.Payments.PaymentReminderNotifier do
  import Swoosh.Email

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Mail
  alias QuantumBilling.Payments
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Workers.EmailWorker
  alias QuantumBillingWeb.Endpoint
  alias QuantumBillingWeb.Format

  def deliver_async(%Invoice{} = invoice, step) do
    business = Repo.business()

    recipient = String.trim(invoice.client_email || "")

    if recipient == "" do
      {:error, :invalid_recipient}
    else
      with {:ok, delivery} <-
             Mail.record_queued(%{
               to_email: recipient,
               kind: "reminder",
               subject: "Payment reminder: Invoice #{invoice.invoice_number}",
               invoice_id: invoice.id
             }),
           {:ok, _job} <-
             %{
               "delivery_id" => delivery.id,
               "invoice_id" => invoice.id,
               "payment_reminder" => true,
               "step" => step,
               "business_id" => business.id
             }
             |> EmailWorker.new()
             |> Oban.insert() do
        {:ok, delivery}
      end
    end
  end

  def build_email(recipient, %Invoice{} = invoice) do
    organization = Settings.get_organization()
    business = Repo.business()
    {from_name, from_email} = Mail.sender(organization, invoice.company_name)

    pdf_url =
      Endpoint.url() <>
        "/p/#{business.slug}/#{invoice.public_token}/pdf"

    payment_url = Payments.safe_payment_url(invoice.razorpay_payment_url)

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject("Payment reminder: Invoice #{invoice.invoice_number}")
      |> html_body("""
      <div style="font-family:Arial,sans-serif;max-width:600px;margin:auto">
        <h2>Payment reminder</h2>
        <p>Dear #{escape(invoice.client_name || "Customer")},</p>
        <p>This is a friendly reminder that payment for invoice
        <strong>#{escape(invoice.invoice_number)}</strong> is pending.</p>
        <p>Amount due: <strong>#{escape(Format.money(invoice.grand_total, invoice.currency))}</strong></p>
        <p>Due date: <strong>#{invoice.due_date}</strong></p>
        <p><a href="#{escape(pdf_url)}">View invoice PDF</a></p>
        #{payment_link_html(payment_url)}
        <p>Thank you,<br/>#{escape(from_name)}</p>
      </div>
      """)
      |> text_body("""
      Dear #{invoice.client_name || "Customer"},

      Payment for invoice #{invoice.invoice_number} is pending.

      Amount due: #{Format.money(invoice.grand_total, invoice.currency)}
      Due date: #{invoice.due_date}

      View invoice PDF: #{pdf_url}
      #{if payment_url, do: "Pay online: #{payment_url}", else: ""}

      Thank you,
      #{from_name}
      """)
      |> Mail.reply_to(organization)

    {:ok, email}
  end

  defp payment_link_html(nil), do: ""

  defp payment_link_html(url) do
    ~s(<p><a href="#{escape(url)}">Pay invoice online</a></p>)
  end

  defp escape(nil), do: ""

  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
