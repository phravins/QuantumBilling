defmodule QuantumBilling.InvoiceNotifier do
  @moduledoc """
  Notifier for dispatching GST Invoices with PDF attachments via email.
  Supports both default mailer and custom Organization SMTP server configuration.
  """

  import Swoosh.Email

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Mailer
  alias QuantumBilling.Settings
  alias QuantumBillingWeb.InvoicePdfGenerator

  @doc """
  Delivers an invoice email with attached PDF to the specified recipient email address.
  """
  def deliver_invoice_pdf(recipient_email, %Invoice{} = invoice)
      when is_binary(recipient_email) do
    {:ok, pdf_content} = InvoicePdfGenerator.generate_pdf(invoice)

    org = Settings.get_organization()

    from_email =
      cond do
        org && org.smtp_from_email && String.trim(org.smtp_from_email) != "" ->
          String.trim(org.smtp_from_email)

        org && org.email && String.trim(org.email) != "" ->
          String.trim(org.email)

        true ->
          System.get_env("MAILER_FROM_EMAIL", "invoices@quantumbilling.in")
      end

    from_name =
      cond do
        org && org.smtp_from_name && String.trim(org.smtp_from_name) != "" ->
          String.trim(org.smtp_from_name)

        invoice.company_name && String.trim(invoice.company_name) != "" ->
          String.trim(invoice.company_name)

        org && org.company_name && String.trim(org.company_name) != "" ->
          String.trim(org.company_name)

        true ->
          "QuantumBilling"
      end

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

    email =
      new()
      |> to(recipient_email)
      |> from({from_name, from_email})
      |> subject(subject)
      |> html_body(html_body)
      |> attachment(attachment)

    deliver_email(email, org)
  end

  defp deliver_email(email, org) do
    if org && org.smtp_host && String.trim(org.smtp_host) != "" do
      ssl_opts = [
        cacerts: :public_key.cacerts_get(),
        verify: :verify_none,
        versions: [:"tlsv1.2", :"tlsv1.3"]
      ]

      port = org.smtp_port || 587
      ssl? = org.smtp_ssl == true or port == 465
      has_username? = org.smtp_username && String.trim(org.smtp_username) != ""

      smtp_config = [
        relay: String.trim(org.smtp_host),
        port: port,
        username: (org.smtp_username && String.trim(org.smtp_username)) || "",
        password: org.smtp_password || "",
        ssl: ssl?,
        ssl_options: ssl_opts,
        tls_options: ssl_opts,
        auth: if(has_username?, do: :always, else: :never),
        no_mx_lookups: true
      ]

      smtp_config =
        if ssl? do
          smtp_config
        else
          Keyword.put(smtp_config, :tls, :always)
        end

      case Swoosh.Adapters.SMTP.deliver(email, smtp_config) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, format_smtp_error(reason)}
      end
    else
      case Mailer.deliver(email) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, format_smtp_error(reason)}
      end
    end
  end

  def format_smtp_error({:retries_exceeded, inner_reason}) do
    "SMTP retries exceeded: #{format_smtp_error(inner_reason)}"
  end

  def format_smtp_error({:network_failure, host, {:error, :timeout}}) do
    "Network timeout connecting to #{to_string(host)}. Check host, port, and firewall."
  end

  def format_smtp_error({:network_failure, host, {:error, :econnrefused}}) do
    "Connection refused by #{to_string(host)}. Check host and port."
  end

  def format_smtp_error({:network_failure, host, {:error, {:options, :incompatible, _}}}) do
    "SSL/TLS handshake failed with #{to_string(host)}. Please verify port and SSL settings."
  end

  def format_smtp_error({:network_failure, host, detail}) do
    "Network failure connecting to #{to_string(host)}: #{format_smtp_error(detail)}"
  end

  def format_smtp_error({:missing_requirement, _host, :auth}) do
    "SMTP server requires STARTTLS or authentication. Verify port (587 vs 465) and SSL toggle."
  end

  def format_smtp_error(:auth_failed),
    do: "SMTP authentication failed. Please check username & password."

  def format_smtp_error({:auth_failed, _}),
    do: "SMTP authentication failed. Please check username & password."

  def format_smtp_error(:econnrefused),
    do: "Connection refused by SMTP server. Check host and port."

  def format_smtp_error(:timeout), do: "Connection to SMTP server timed out."
  def format_smtp_error(:nxdomain), do: "SMTP host not found (DNS lookup failed)."

  def format_smtp_error(charlist) when is_list(charlist) do
    case List.to_string(charlist) do
      str when is_binary(str) -> str
      _ -> inspect(charlist)
    end
  rescue
    _ -> inspect(charlist)
  end

  def format_smtp_error({reason, detail}),
    do: "#{format_smtp_error(reason)}: #{format_smtp_error(detail)}"

  def format_smtp_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_smtp_error(reason) when is_binary(reason), do: reason
  def format_smtp_error(reason), do: inspect(reason)
end
