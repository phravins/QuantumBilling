defmodule QuantumBillingWeb.InvoicePdfController do
  @moduledoc """
  The invoice as a document, outside the app layout.

    * `show/2` - the print page (the browser can save it as PDF)
    * `download/2` - a server-side PDF via `InvoiceDoc.PDF`, or a redirect to
      the print page when no headless browser is installed
    * `public/2` - the same for a customer, by public token
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Invoices
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Extras
  alias QuantumBillingWeb.InvoicePdfGenerator

  def show(conn, %{"id" => id}) do
    case Invoices.get_invoice(id) do
      nil ->
        conn
        |> put_flash(:error, "That invoice does not exist.")
        |> redirect(to: ~p"/invoices")

      invoice ->
        # Same layout and component as InvoiceShowLive.
        {doc, accent, logo} = Templates.document_for(invoice)

        conn
        |> put_root_layout(false)
        |> put_layout(false)
        |> render(:show,
          invoice: invoice,
          doc: doc,
          accent: accent,
          logo: logo,
          extras: Extras.build(invoice, doc)
        )
    end
  end

  def download(conn, %{"id" => id}) do
    case Invoices.get_invoice(id) do
      nil ->
        conn
        |> put_flash(:error, "That invoice does not exist.")
        |> redirect(to: ~p"/invoices")

      invoice ->
        case InvoicePdfGenerator.generate_pdf(invoice) do
          {:ok, pdf} ->
            send_download(conn, {:binary, pdf},
              filename: "#{invoice.invoice_number || "invoice"}.pdf",
              content_type: "application/pdf"
            )

          {:error, :no_renderer} ->
            conn
            |> put_flash(
              :info,
              "Server-side PDF export is not available here — use your browser's " <>
                "Print › Save as PDF on this page."
            )
            |> redirect(to: ~p"/invoices/#{invoice.id}/pdf")

          {:error, reason} ->
            conn
            |> put_flash(:error, "That PDF could not be produced (#{inspect(reason)}).")
            |> redirect(to: ~p"/invoices/#{invoice.id}/pdf")
        end
    end
  end

  def public(conn, %{"token" => token} = params) do
    # No session business for a visitor: the link names it. The endpoint
    # clears it again before the next request on this connection.
    business =
      QuantumBilling.Repo.put_business(QuantumBilling.Businesses.from_link(params["slug"]))

    case business && Invoices.get_invoice_by_token(token) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: QuantumBillingWeb.ErrorHTML)
        |> put_root_layout(false)
        |> put_layout(false)
        |> render(:"404")

      invoice ->
        case InvoicePdfGenerator.generate_pdf(invoice) do
          {:ok, pdf} ->
            send_download(conn, {:binary, pdf},
              filename: "#{invoice.invoice_number || "invoice"}.pdf",
              content_type: "application/pdf"
            )

          {:error, _reason} ->
            # No renderer: send the print page for the browser to save as PDF.
            {doc, accent, logo} = Templates.document_for(invoice)

            conn
            |> put_root_layout(false)
            |> put_layout(false)
            |> render(:show,
              invoice: invoice,
              doc: doc,
              accent: accent,
              # A visitor has no session, so /uploads refuses them.
              logo: InvoicePdfGenerator.inline_logo(logo),
              extras: Extras.build(invoice, doc, inline: true)
            )
        end
    end
  end
end
