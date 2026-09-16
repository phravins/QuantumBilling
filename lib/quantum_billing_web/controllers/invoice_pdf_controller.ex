defmodule QuantumBillingWeb.InvoicePdfController do
  @moduledoc """
  The invoice as a document: a printable page, and a PDF download.

  `show/2` renders the standalone print-styled page — the browser's own "Save
  as PDF" works from it, and it needs nothing installed on the server.

  `download/2` returns an actual PDF file, printed server-side by
  `QuantumBillingWeb.InvoiceDoc.PDF`. Where no headless browser is installed it
  redirects to the print view and says so, rather than sending something that
  is not a PDF — which is what the mail attachment used to do.

  `public/2` is the same document for a customer, addressed by the invoice's
  public token rather than its id. The public payment page used to link to the
  signed-in route, so "Download PDF" sent the customer to a login screen for an
  application they have no account on.

  All three render outside the app layout on purpose: the sidebar and page
  chrome have no business on a document going to a client.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Invoices
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoicePdfGenerator

  def show(conn, %{"id" => id}) do
    case Invoices.get_invoice(id) do
      nil ->
        conn
        |> put_flash(:error, "That invoice does not exist.")
        |> redirect(to: ~p"/invoices")

      invoice ->
        # The same layout `InvoiceShowLive` resolves, rendered by the same
        # component, so the printed document and the one on screen cannot
        # disagree about what appears on them.
        {doc, accent, logo} = Templates.document_for(invoice)

        conn
        |> put_root_layout(false)
        |> put_layout(false)
        |> render(:show, invoice: invoice, doc: doc, accent: accent, logo: logo)
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

  def public(conn, %{"token" => token}) do
    case Invoices.get_invoice_by_token(token) do
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
            # No renderer here: hand over the print-styled page, which the
            # customer's own browser can save as a PDF.
            conn
            |> put_root_layout(false)
            |> put_layout(false)
            |> render(:show,
              invoice: invoice,
              doc: elem(Templates.document_for(invoice), 0),
              accent: elem(Templates.document_for(invoice), 1),
              logo: elem(Templates.document_for(invoice), 2)
            )
        end
    end
  end
end
