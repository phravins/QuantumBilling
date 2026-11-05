defmodule QuantumBillingWeb.EWayBillPdfController do
  @moduledoc """
  The e-way bill document (Form GST EWB-01), outside the app layout.

  `show/2` renders it (`?print=1` opens the print dialog). `download/2` makes
  a PDF with `InvoiceDoc.PDF`, or redirects to the print view if no browser
  is installed. The id is the bill's, since an invoice can have several.
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
