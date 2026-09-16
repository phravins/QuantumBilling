defmodule QuantumBilling.InvoiceNotifier do
  @moduledoc """
  Composes the mail that carries an invoice to its customer.

  Transport is `QuantumBilling.Mail`'s business — this module decides what the
  message says and what is attached to it.

  ## Queued, not sent inline

  `deliver_invoice_pdf_async/3` is what the application uses. Rendering a PDF
  and waiting on a relay takes seconds that a LiveView, a webhook or a
  recurring-billing sweep does not have: a slow relay used to stall the request
  that triggered it, and a failed one lost the message entirely once the flash
  faded. The work now belongs to `QuantumBilling.Workers.EmailWorker`, which
  retries with backoff and records every attempt in the delivery ledger.

  `deliver_invoice_pdf/2` still sends inline, for the one case that genuinely
  needs the answer immediately: the "send test email" button in Settings, whose
  entire purpose is to report what the relay said.
  """

  import Swoosh.Email

  require Logger

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Mail
  alias QuantumBilling.Settings
  alias QuantumBilling.Workers.EmailWorker
  alias QuantumBillingWeb.InvoicePdfGenerator

  @doc """
  Queues an invoice email and returns the ledger row for it.

  Returns `{:ok, delivery}` once the work is durably recorded — not once the
  mail has arrived — or `{:error, reason}` if the recipient is unusable or the
  job cannot be enqueued.
  """
  def deliver_invoice_pdf_async(recipient_email, %Invoice{} = invoice, opts \\ []) do
    kind = Keyword.get(opts, :kind, "invoice")

    with {:ok, recipient} <- validate_recipient(recipient_email),
         {:ok, delivery} <-
           Mail.record_queued(%{
             to_email: recipient,
             kind: kind,
             subject: subject_for(invoice, sender_name(invoice)),
             invoice_id: invoice.id
           }),
         {:ok, _job} <-
           %{"delivery_id" => delivery.id, "invoice_id" => invoice.id, "kind" => kind}
           |> EmailWorker.new()
           |> Oban.insert() do
      {:ok, delivery}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds and sends the invoice email immediately.

  Returns `{:ok, metadata}` or `{:error, message}`, where the message is
  already readable — it is shown to whoever pressed the button.
  """
  def deliver_invoice_pdf(recipient_email, %Invoice{} = invoice) do
    with {:ok, recipient} <- validate_recipient(recipient_email),
         {:ok, email} <- build_email(recipient, invoice) do
      Mail.deliver(email, Settings.get_organization())
    end
  end

  @doc """
  The finished `Swoosh.Email` for an invoice, or `{:error, message}`.

  Public so the mail worker can compose and send in one step without repeating
  any of this.
  """
  def build_email(recipient, %Invoice{} = invoice) do
    organization = Settings.get_organization()
    {from_name, from_email} = Mail.sender(organization, invoice.company_name)

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject_for(invoice, from_name))
      |> html_body(html_content(invoice, from_name))
      |> text_body(text_content(invoice, from_name))
      |> attachment(document_attachment(invoice))

    {:ok, email}
  end

  # The invoice itself, as a PDF where one can be printed.
  #
  # Where it cannot — no headless browser on this machine — the HTML document
  # goes instead, named `.html` and typed as HTML. The customer gets something
  # they can open either way; what they do not get is an HTML file called
  # `INV-1234.pdf`, which is what used to be attached and what mail clients
  # refuse to open.
  defp document_attachment(%Invoice{} = invoice) do
    name = invoice.invoice_number || "invoice"

    case InvoicePdfGenerator.generate_pdf(invoice) do
      {:ok, pdf} ->
        Swoosh.Attachment.new({:data, pdf},
          filename: "#{name}.pdf",
          content_type: "application/pdf"
        )

      {:error, reason} ->
        Logger.warning(
          "[InvoiceNotifier] #{name}: no PDF (#{inspect(reason)}), attaching HTML instead"
        )

        Swoosh.Attachment.new(
          {:data, InvoicePdfGenerator.generate_html(invoice, print_button: false)},
          filename: "#{name}.html",
          content_type: "text/html"
        )
    end
  end

  @doc "The subject line for an invoice, used by both the ledger and the mail."
  def subject_for(%Invoice{} = invoice, from_name) do
    "#{invoice.invoice_type || "Tax Invoice"} #{invoice.invoice_number} from #{from_name}"
  end

  defp sender_name(%Invoice{} = invoice) do
    {name, _email} = Mail.sender(Settings.get_organization(), invoice.company_name)
    name
  end

  # Checked here rather than at the relay: a blank or malformed recipient is a
  # bug in the caller, and finding out three retries later costs a customer
  # their invoice.
  defp validate_recipient(email) when is_binary(email) do
    trimmed = String.trim(email)

    if Regex.match?(~r/^[^@,;\s]+@[^@,;\s]+$/, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_recipient}
    end
  end

  defp validate_recipient(_email), do: {:error, :invalid_recipient}

  defp html_content(%Invoice{} = invoice, from_name) do
    """
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e5e7eb; border-radius: 8px;">
      <h2 style="color: #1f2937; margin-top: 0;">Tax Invoice Details</h2>
      <p style="color: #4b5563; font-size: 15px;">
        Dear #{escape(invoice.client_name || "Customer")},
      </p>
      <p style="color: #4b5563; font-size: 15px;">
        Please find attached your #{escape(invoice.invoice_type || "Tax Invoice")}
        <strong>#{escape(invoice.invoice_number)}</strong> for
        <strong>&#8377;#{invoice.grand_total}</strong> issued on
        <strong>#{invoice.invoice_date}</strong>.
      </p>
      <div style="background-color: #f3f4f6; padding: 16px; border-radius: 6px; margin: 20px 0;">
        <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Invoice Number:</td>
            <td style="padding: 4px 0; font-weight: bold; color: #111827;">#{escape(invoice.invoice_number)}</td>
          </tr>
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Grand Total:</td>
            <td style="padding: 4px 0; font-weight: bold; color: #059669;">&#8377;#{invoice.grand_total}</td>
          </tr>
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Due Date:</td>
            <td style="padding: 4px 0; color: #111827;">#{invoice.due_date || invoice.invoice_date}</td>
          </tr>
          #{irn_row(invoice)}
        </table>
      </div>
      <p style="color: #6b7280; font-size: 13px; margin-bottom: 0;">
        Thank you for your business!<br/>
        <strong>#{escape(from_name)}</strong>
      </p>
    </div>
    """
  end

  defp irn_row(%Invoice{irn: nil}), do: ""

  defp irn_row(%Invoice{irn: irn}) do
    """
    <tr>
      <td style="padding: 4px 0; color: #6b7280;">IRN:</td>
      <td style="padding: 4px 0; font-family: monospace; font-size: 12px; color: #2563eb;">#{escape(irn)}</td>
    </tr>
    """
  end

  # Mail clients that refuse HTML, and spam filters that score its absence,
  # both want this — and it costs one function.
  defp text_content(%Invoice{} = invoice, from_name) do
    """
    Dear #{invoice.client_name || "Customer"},

    Please find attached your #{invoice.invoice_type || "Tax Invoice"} #{invoice.invoice_number}
    for Rs. #{invoice.grand_total}, issued on #{invoice.invoice_date}.

    Invoice number: #{invoice.invoice_number}
    Grand total:    Rs. #{invoice.grand_total}
    Due date:       #{invoice.due_date || invoice.invoice_date}
    #{if invoice.irn, do: "IRN:            #{invoice.irn}\n", else: ""}
    Thank you for your business.
    #{from_name}
    """
  end

  # Customer-supplied names and numbers go into an HTML document, so they are
  # escaped rather than trusted — the same rule that applies on a page.
  defp escape(nil), do: ""

  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  @doc """
  Kept for callers that formatted their own transport errors.

  Delegates to `QuantumBilling.Mail.error_message/1`, which is now the single
  place that turns an SMTP failure into a sentence.
  """
  defdelegate format_smtp_error(reason), to: Mail, as: :error_message
end
