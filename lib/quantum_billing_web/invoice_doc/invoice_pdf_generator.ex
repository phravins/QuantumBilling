defmodule QuantumBillingWeb.InvoicePdfGenerator do
  @moduledoc """
  Generates clean, printable HTML and PDF document payloads for invoices.

  Supports rendering full-bleed standalone documents suitable for PDF saving,
  browser printing, and emailing as PDF attachments.
  """
  use QuantumBillingWeb, :html

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Renderer

  @doc """
  Generates a standalone, self-contained HTML string of the invoice including all
  embedded CSS, stylesheets, logo, and document layout markup.
  """
  def generate_html(%Invoice{} = invoice) do
    invoice = ensure_associations_loaded(invoice)
    {doc, accent, logo} = Templates.document_for(invoice)

    assigns = %{
      doc: doc,
      invoice: invoice,
      accent: accent,
      logo: logo
    }

    rendered = render("document.html", assigns)
    {:safe, iodata} = Phoenix.HTML.html_escape(rendered)
    IO.iodata_to_binary(iodata)
  end

  defp ensure_associations_loaded(%Invoice{} = invoice) do
    items =
      case invoice.items do
        %Ecto.Association.NotLoaded{} ->
          if invoice.id, do: QuantumBilling.Repo.preload(invoice, :items).items, else: []

        nil ->
          []

        list when is_list(list) ->
          list

        _ ->
          []
      end

    client =
      case invoice.client do
        %Ecto.Association.NotLoaded{} ->
          if invoice.id, do: QuantumBilling.Repo.preload(invoice, :client).client, else: nil

        other ->
          other
      end

    %{invoice | items: items, client: client}
  end

  @doc """
  Generates a binary payload suitable for email attachments or direct file downloads.
  """
  def generate_pdf(%Invoice{} = invoice) do
    html = generate_html(invoice)
    {:ok, html}
  end

  def render("document.html", assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@invoice.invoice_number}</title>
        <style>
          @page { size: A4; margin: 12mm; }
          body { margin: 0; padding: 16px; font-family: system-ui, -apple-system, sans-serif; background: #ffffff; color: #000000; }
          @media print {
            body { padding: 0; }
            .no-print { display: none !important; }
          }
        </style>
        <Renderer.stylesheet doc={@doc} />
      </head>
      <body>
        <div class="no-print" style="margin-bottom: 16px; text-align: right;">
          <button
            onclick="window.print()"
            style="padding: 8px 16px; background: #2563eb; color: #fff; border: none; border-radius: 6px; cursor: pointer; font-weight: 500;"
          >
            Print / Save as PDF
          </button>
        </div>
        <Renderer.document doc={@doc} invoice={@invoice} accent={@accent} logo={@logo} />
      </body>
    </html>
    """
  end
end
