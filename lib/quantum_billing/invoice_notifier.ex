defmodule QuantumBilling.InvoiceNotifier do
  @moduledoc """
  Notifier for dispatching GST Invoices with PDF attachments via email.
  """

  import Swoosh.Email

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Mailer
  alias QuantumBillingWeb.InvoicePdfGenerator

  @doc """
  Delivers an invoice email with attached PDF to the specified recipient email address.
  """
  def deliver_invoice_pdf(recipient_email, %Invoice{} = invoice)
      when is_binary(recipient_email) do
    {:ok, pdf_content} = InvoicePdfGenerator.generate_pdf(invoice)

    from_email = System.get_env("MAILER_FROM_EMAIL", "invoices@quantumbilling.in")
    from_name = invoice.company_name || "QuantumBilling"

    attachment =
      Swoosh.Attachment.new(
        {:data, pdf_content},
        filename: "#{invoice.invoice_number}.pdf",
        content_type: "application/pdf"
      )

    subject = "Tax Invoice #{invoice.invoice_number} from #{from_name}"

    html_body = """
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e5e7eb; border-radius: 8px;">
      <h2 style="color: #1f2937; margin-top: 0;">Tax Invoice Details</h2>
      <p style="color: #4b5563; font-size: 15px;">
        Dear Customer,
      </p>
      <p style="color: #4b5563; font-size: 15px;">
        Please find attached your Tax Invoice <strong>#{invoice.invoice_number}</strong> for <strong>₹#{invoice.grand_total}</strong> issued on <strong>#{invoice.invoice_date}</strong>.
      </p>
      <div style="background-color: #f3f4f6; padding: 16px; border-radius: 6px; margin: 20px 0;">
        <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Invoice Number:</td>
            <td style="padding: 4px 0; font-weight: bold; color: #111827;">#{invoice.invoice_number}</td>
          </tr>
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Grand Total:</td>
            <td style="padding: 4px 0; font-weight: bold; color: #059669;">₹#{invoice.grand_total}</td>
          </tr>
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Due Date:</td>
            <td style="padding: 4px 0; color: #111827;">#{invoice.due_date}</td>
          </tr>
          #{if invoice.irn, do: "<tr><td style=\"padding: 4px 0; color: #6b7280;\">IRN:</td><td style=\"padding: 4px 0; font-family: monospace; font-size: 12px; color: #2563eb;\">#{invoice.irn}</td></tr>", else: ""}
        </table>
      </div>
      <p style="color: #6b7280; font-size: 13px; margin-bottom: 0;">
        Thank you for your business!<br/>
        <strong>#{from_name}</strong>
      </p>
    </div>
    """

    new()
    |> to(recipient_email)
    |> from({from_name, from_email})
    |> subject(subject)
    |> html_body(html_body)
    |> attachment(attachment)
    |> Mailer.deliver()
  end
end
