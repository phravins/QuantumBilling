defmodule QuantumBillingWeb.InvoicePdfController do
  @moduledoc """
  The printable invoice, for saving as a PDF.

  Rendered as a standalone print-styled page that opens the browser's print
  dialog on load, where "Save as PDF" produces the file. Every server-side PDF
  generator available to Elixir shells out to a browser or a `wkhtmltopdf`
  binary that has to be installed alongside the app; going through the browser
  already on the user's machine keeps the download working everywhere with no
  runtime dependency to install or keep patched.

  It renders outside the app layout on purpose — the sidebar and page chrome
  have no business on a document going to a client.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBillingWeb.InvoiceDoc.Layout

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
        organization = Settings.get_organization()

        conn
        |> put_root_layout(false)
        |> put_layout(false)
        |> render(:show,
          invoice: invoice,
          doc: Layout.from_legacy(organization),
          accent: organization.doc_accent_color || "#18181b",
          logo: presence(organization.doc_logo_path)
        )
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
