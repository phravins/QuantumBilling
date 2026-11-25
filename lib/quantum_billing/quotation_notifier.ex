defmodule QuantumBilling.QuotationNotifier do
  @moduledoc """
  Composes the email that carries a quotation to its client; `QuantumBilling.Mail`
  sends it.

  The mail has the quotation's PDF attached and the client's link, where it
  can be accepted or declined. `deliver_async/2` records the delivery and
  queues it on `EmailWorker`, which retries and records each attempt.
  """

  import Swoosh.Email

  require Logger

  alias QuantumBilling.Mail
  alias QuantumBilling.Quotations
  alias QuantumBilling.Quotations.Quotation
  alias QuantumBilling.Settings
  alias QuantumBilling.Workers.EmailWorker
  alias QuantumBillingWeb.Format
  alias QuantumBillingWeb.InvoiceDoc.QuotationLayout
  alias QuantumBillingWeb.InvoicePdfGenerator

  @doc "Queues a quotation email: `{:ok, delivery}` once recorded, or `{:error, reason}`."
  def deliver_async(recipient_email, %Quotation{} = quotation) do
    with {:ok, recipient} <- validate_recipient(recipient_email),
         {:ok, delivery} <-
           Mail.record_queued(%{
             to_email: recipient,
             kind: "quotation",
             subject: subject_for(quotation, sender_name(quotation))
           }),
         {:ok, _job} <-
           %{"delivery_id" => delivery.id, "quotation_id" => quotation.id, "kind" => "quotation"}
           |> EmailWorker.new()
           |> Oban.insert() do
      {:ok, delivery}
    end
  end

  @doc "The finished `Swoosh.Email` for a quotation. Used by the mail worker."
  def build_email(recipient, %Quotation{} = quotation) do
    organization = Settings.get_organization()
    {from_name, from_email} = Mail.sender(organization, quotation.company_name)
    link = public_url(quotation)

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject_for(quotation, from_name))
      |> html_body(html_content(quotation, from_name, link))
      |> text_body(text_content(quotation, from_name, link))
      |> attachment(document_attachment(quotation))
      |> Mail.reply_to(organization)

    {:ok, email}
  end

  @doc "The subject line, used by both the ledger and the mail."
  def subject_for(%Quotation{} = quotation, from_name),
    do: "Quotation #{quotation.number} from #{from_name}"

  @doc "The client's full link to `quotation`, or `nil` before it has a token."
  def public_url(%Quotation{public_token: token}) when is_binary(token) and token != "",
    do: QuantumBillingWeb.Endpoint.url() <> QuantumBillingWeb.PublicQuotationLive.path(token)

  def public_url(_quotation), do: nil

  defp document_attachment(%Quotation{} = quotation) do
    document = Quotations.as_document(quotation)
    name = "Quotation-#{quotation.number}"

    case InvoicePdfGenerator.generate_pdf(document, adapt: &QuotationLayout.adapt/1) do
      {:ok, pdf} ->
        Swoosh.Attachment.new({:data, pdf},
          filename: "#{name}.pdf",
          content_type: "application/pdf"
        )

      {:error, reason} ->
        Logger.warning(
          "[QuotationNotifier] #{quotation.number}: no PDF (#{inspect(reason)}), attaching HTML instead"
        )

        Swoosh.Attachment.new(
          {:data,
           InvoicePdfGenerator.generate_html(document,
             print_button: false,
             adapt: &QuotationLayout.adapt/1
           )},
          filename: "#{name}.html",
          content_type: "text/html"
        )
    end
  end

  defp sender_name(%Quotation{} = quotation) do
    {name, _email} = Mail.sender(Settings.get_organization(), quotation.company_name)
    name
  end

  defp validate_recipient(email) when is_binary(email) do
    trimmed = String.trim(email)

    if Regex.match?(~r/^[^@,;\s]+@[^@,;\s]+$/, trimmed),
      do: {:ok, trimmed},
      else: {:error, :invalid_recipient}
  end

  defp validate_recipient(_email), do: {:error, :invalid_recipient}

  defp html_content(%Quotation{} = quotation, from_name, link) do
    total = Format.money(quotation.grand_total, quotation.currency)

    """
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e5e7eb; border-radius: 8px;">
      <h2 style="color: #1f2937; margin-top: 0;">Quotation #{escape(quotation.number)}</h2>
      <p style="color: #4b5563; font-size: 15px;">Dear #{escape(quotation.client_name || "Customer")},</p>
      <p style="color: #4b5563; font-size: 15px;">
        Please find attached our quotation <strong>#{escape(quotation.number)}</strong> for
        <strong>#{escape(total)}</strong>, valid until <strong>#{quotation.valid_until}</strong>.
      </p>
      <div style="background-color: #f3f4f6; padding: 16px; border-radius: 6px; margin: 20px 0;">
        <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Quotation Number:</td>
            <td style="padding: 4px 0; font-weight: bold; color: #111827;">#{escape(quotation.number)}</td>
          </tr>
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Total:</td>
            <td style="padding: 4px 0; font-weight: bold; color: #111827;">#{escape(total)}</td>
          </tr>
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Valid Until:</td>
            <td style="padding: 4px 0; color: #111827;">#{quotation.valid_until}</td>
          </tr>
        </table>
      </div>
      #{link_button(link)}
      <p style="color: #6b7280; font-size: 13px; margin-bottom: 0;">
        Thank you for considering us.<br/>
        <strong>#{escape(from_name)}</strong>
      </p>
    </div>
    """
  end

  defp link_button(nil), do: ""

  defp link_button(link) do
    """
    <p style="margin: 20px 0;">
      <a href="#{escape(link)}" style="display: inline-block; background-color: #4f46e5; color: #ffffff; padding: 10px 18px; border-radius: 6px; text-decoration: none; font-weight: bold; font-size: 14px;">
        View, accept or decline
      </a>
    </p>
    """
  end

  defp text_content(%Quotation{} = quotation, from_name, link) do
    """
    Dear #{quotation.client_name || "Customer"},

    Please find attached our quotation #{quotation.number} for #{plain_amount(quotation)},
    valid until #{quotation.valid_until}.

    Quotation number: #{quotation.number}
    Total:            #{plain_amount(quotation)}
    Valid until:      #{quotation.valid_until}
    #{if link, do: "\nView, accept or decline it here: #{link}\n", else: ""}
    Thank you for considering us.
    #{from_name}
    """
  end

  # Plain-text mail keeps to ASCII: "Rs. 1,50,000" or "AED 150,000".
  defp plain_amount(%Quotation{currency: currency, grand_total: total})
       when currency in [nil, "INR"],
       do: "Rs. " <> Format.figure(total)

  defp plain_amount(%Quotation{currency: currency, grand_total: total}),
    do:
      currency <>
        " " <>
        Format.figure(total, 0, QuantumBilling.Currency.get(currency).grouping, currency)

  defp escape(nil), do: ""

  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
