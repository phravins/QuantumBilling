defmodule QuantumBillingWeb.EInvoiceController do
  @moduledoc """
  Downloads an invoice's GST e-invoice (INV-01) data as XML.

  A plain controller rather than a LiveView event for the same reason the PDF
  view is one: this hands the browser a file, which is a real navigation.

  When the invoice is not in a state the schema can describe, this redirects with
  the reasons rather than writing the file anyway. A tax document that is quietly
  wrong is worse than one that was never produced — and the messages name what to
  fix, so refusing is actionable.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.EInvoice
  alias QuantumBilling.Invoices

  def show(conn, %{"id" => id}) do
    case Invoices.get_invoice(id) do
      nil ->
        conn
        |> put_flash(:error, "That invoice does not exist.")
        |> redirect(to: ~p"/invoices")

      invoice ->
        download(conn, invoice)
    end
  end

  defp download(conn, invoice) do
    case EInvoice.xml_for(invoice) do
      {:ok, xml} ->
        send_download(conn, {:binary, xml},
          filename: "einvoice-#{invoice.invoice_number}.xml",
          content_type: "application/xml"
        )

      {:error, problems} ->
        conn
        |> put_flash(:error, "This invoice is not ready to report: " <> Enum.join(problems, " "))
        |> redirect(to: ~p"/invoices/#{invoice.id}")
    end
  end
end
