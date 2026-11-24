defmodule QuantumBillingWeb.QuotationPdfController do
  @moduledoc """
  The quotation as a document, through the invoice pipeline: the quotation is
  rendered as an unsaved invoice (`Quotations.as_document/1`) with its design
  adapted by `InvoiceDoc.QuotationLayout` (titled "Quotation", "Valid Until",
  no payment block).

    * `show/2` - the print page (the browser can save it as PDF)
    * `download/2` - a server-side PDF, or a redirect to the print page when
      no headless browser is installed
    * `public/2` - the client's PDF from the public link, with no session
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Quotations
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Extras
  alias QuantumBillingWeb.InvoiceDoc.QuotationLayout
  alias QuantumBillingWeb.InvoicePdfGenerator

  def show(conn, %{"id" => id}) do
    case Quotations.get_quotation(id) do
      nil ->
        not_found(conn)

      quotation ->
        document = Quotations.as_document(quotation)
        {doc, accent, logo} = Templates.document_for(document)
        doc = QuotationLayout.adapt(doc)

        conn
        |> put_view(html: QuantumBillingWeb.InvoicePdfHTML)
        |> put_root_layout(false)
        |> put_layout(false)
        |> render(:show,
          invoice: document,
          doc: doc,
          accent: accent,
          logo: logo,
          extras: Extras.build(document, doc)
        )
    end
  end

  def download(conn, %{"id" => id}) do
    case Quotations.get_quotation(id) do
      nil ->
        not_found(conn)

      quotation ->
        quotation
        |> Quotations.as_document()
        |> InvoicePdfGenerator.generate_pdf(adapt: &QuotationLayout.adapt/1)
        |> case do
          {:ok, pdf} ->
            send_download(conn, {:binary, pdf},
              filename: "Quotation-#{quotation.number}.pdf",
              content_type: "application/pdf"
            )

          {:error, :busy} ->
            conn
            |> put_flash(
              :error,
              "The server is busy making other PDFs. Please try again in a few seconds."
            )
            |> redirect(to: ~p"/quotations/#{quotation}/pdf")

          {:error, :no_renderer} ->
            conn
            |> put_flash(
              :info,
              "Server-side PDF export is not available here — use your browser's " <>
                "Print › Save as PDF on this page."
            )
            |> redirect(to: ~p"/quotations/#{quotation}/pdf")

          {:error, reason} ->
            conn
            |> put_flash(
              :error,
              "That PDF could not be produced. #{QuantumBilling.ErrorMessages.text(reason)}"
            )
            |> redirect(to: ~p"/quotations/#{quotation}/pdf")
        end
    end
  end

  def public(conn, %{"token" => token} = params) do
    # No session business for a visitor: the link names it. The endpoint
    # clears it again before the next request on this connection.
    business =
      QuantumBilling.Repo.put_business(QuantumBilling.Businesses.from_link(params["slug"]))

    case business && Quotations.get_quotation_by_token(token) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: QuantumBillingWeb.ErrorHTML)
        |> put_root_layout(false)
        |> put_layout(false)
        |> render(:"404")

      quotation ->
        document = Quotations.as_document(quotation)

        case InvoicePdfGenerator.generate_pdf(document, adapt: &QuotationLayout.adapt/1) do
          {:ok, pdf} ->
            send_download(conn, {:binary, pdf},
              filename: "Quotation-#{quotation.number}.pdf",
              content_type: "application/pdf"
            )

          {:error, :busy} ->
            conn
            |> put_resp_header("retry-after", "5")
            |> send_resp(
              :service_unavailable,
              "The server is busy making other PDFs. Please try again in a few seconds."
            )

          {:error, _reason} ->
            # No renderer: send the print page for the browser to save as PDF.
            {doc, accent, logo} = Templates.document_for(document)
            doc = QuotationLayout.adapt(doc)

            conn
            |> put_view(html: QuantumBillingWeb.InvoicePdfHTML)
            |> put_root_layout(false)
            |> put_layout(false)
            |> render(:show,
              invoice: document,
              doc: doc,
              accent: accent,
              # A visitor has no session, so /uploads refuses them.
              logo: InvoicePdfGenerator.inline_logo(logo),
              extras: Extras.build(document, doc, inline: true)
            )
        end
    end
  end

  defp not_found(conn) do
    conn
    |> put_flash(:error, "That quotation does not exist.")
    |> redirect(to: ~p"/quotations")
  end
end
