defmodule QuantumBillingWeb.EInvoiceController do
  @moduledoc """
  Downloads an invoice's e-invoice (INV-01) XML. If the invoice can't be
  described yet, redirects with the reasons instead of writing a wrong file.
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
