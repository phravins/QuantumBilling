defmodule QuantumBillingWeb.EWayBillPdfController do
  @moduledoc """
  The e-way bill as a document: the printable Form GST EWB-01, and a PDF of it.

  `show/2` renders the standalone page — `?print=1` opens the browser's print
  dialog on load, which is what the list page's printer button links to, and
  without it the same page is simply the document on screen.

  `download/2` prints it server-side with `QuantumBillingWeb.InvoiceDoc.PDF`,
  the same headless browser the invoice PDF uses. Where none is installed it
  redirects to the print view and says so, rather than sending something that
  is not a PDF.

  Both render outside the app layout: the sidebar has no business on a document
  that travels with a consignment.

  An invoice without an e-way bill number has no EWB-01 to print, so it is
  turned away rather than rendered as a form full of dashes.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBillingWeb.EWayBillDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.PDF

  def show(conn, %{"id" => id} = params) do
    with_e_way_bill(conn, id, fn invoice ->
      html =
        Document.html(invoice, Settings.get_organization(),
          auto_print: params["print"] in ["1", "true"]
        )

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, html)
    end)
  end

  def download(conn, %{"id" => id}) do
    with_e_way_bill(conn, id, fn invoice ->
      html = Document.html(invoice, Settings.get_organization(), toolbar: false)

      case PDF.render(html) do
        {:ok, pdf} ->
          send_download(conn, {:binary, pdf},
            filename: "ewb-#{invoice.ewb_number}.pdf",
            content_type: "application/pdf"
          )

        {:error, :no_renderer} ->
          conn
          |> put_flash(
            :info,
            "Server-side PDF export is not available here — use your browser's " <>
              "Print › Save as PDF on this page."
          )
          |> redirect(to: ~p"/e-way-bills/#{invoice.id}/print")

        {:error, reason} ->
          conn
          |> put_flash(:error, "That PDF could not be produced (#{inspect(reason)}).")
          |> redirect(to: ~p"/e-way-bills/#{invoice.id}/print")
      end
    end)
  end

  defp with_e_way_bill(conn, id, render) do
    case Invoices.get_invoice(id) do
      nil ->
        conn
        |> put_flash(:error, "That e-way bill does not exist.")
        |> redirect(to: ~p"/e-way-bills")

      %{ewb_number: number} = invoice when is_binary(number) and number != "" ->
        render.(invoice)

      invoice ->
        conn
        |> put_flash(
          :error,
          "Invoice #{invoice.invoice_number} has no e-way bill yet — generate one first."
        )
        |> redirect(to: ~p"/invoices/#{invoice.id}")
    end
  end
end
