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

  ## The id is the bill's

  It used to be the invoice's, back when a bill was columns on the invoice.
  Now that a cancelled bill and the fresh one raised to replace it are two
  rows against the same document, each needs its own address — a URL that
  meant "the invoice's bill" could not name which.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.EWayBills
  alias QuantumBilling.Settings
  alias QuantumBillingWeb.EWayBillDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.PDF

  def show(conn, %{"id" => id} = params) do
    with_e_way_bill(conn, id, fn bill ->
      html =
        Document.html(bill, Settings.get_organization(),
          auto_print: params["print"] in ["1", "true"]
        )

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, html)
    end)
  end

  def download(conn, %{"id" => id}) do
    with_e_way_bill(conn, id, fn bill ->
      html = Document.html(bill, Settings.get_organization(), toolbar: false)

      case PDF.render(html) do
        {:ok, pdf} ->
          send_download(conn, {:binary, pdf},
            filename: "ewb-#{bill.ewb_number}.pdf",
            content_type: "application/pdf"
          )

        {:error, :no_renderer} ->
          conn
          |> put_flash(
            :info,
            "Server-side PDF export is not available here — use your browser's " <>
              "Print › Save as PDF on this page."
          )
          |> redirect(to: ~p"/e-way-bills/#{bill.id}/print")

        {:error, reason} ->
          conn
          |> put_flash(:error, "That PDF could not be produced (#{inspect(reason)}).")
          |> redirect(to: ~p"/e-way-bills/#{bill.id}/print")
      end
    end)
  end

  # The bill carries its invoice and its Part-B history, because the document
  # prints all three.
  defp with_e_way_bill(conn, id, render) do
    case EWayBills.get_e_way_bill(id) do
      nil ->
        conn
        |> put_flash(:error, "That e-way bill does not exist.")
        |> redirect(to: ~p"/e-way-bills")

      bill ->
        render.(bill)
    end
  end
end
