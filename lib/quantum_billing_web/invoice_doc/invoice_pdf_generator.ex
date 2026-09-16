defmodule QuantumBillingWeb.InvoicePdfGenerator do
  @moduledoc """
  The standalone invoice document: one HTML page, and the PDF printed from it.

  ## Two things the document has to carry itself

  It is read outside the application — in a browser tab with no session, in a
  mail client, in a PDF viewer — so every asset has to travel with it. The
  stylesheet is inlined by `Renderer.stylesheet/1`, and the logo is inlined as
  a data URI by `inline_logo/1`: it is stored as `/uploads/…`, a path that
  resolves only against the running server, so in an emailed document and in a
  browser printing from a local file it was simply a broken image. Customers
  saw an unbranded invoice and the customisation looked like it had not worked.

  ## The PDF is a PDF

  `generate_pdf/1` prints the page with `QuantumBillingWeb.InvoiceDoc.PDF`.
  It used to return the HTML string, which the mailer attached as `.pdf`.
  """
  use QuantumBillingWeb, :html

  require Logger

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.PDF
  alias QuantumBillingWeb.InvoiceDoc.Renderer

  @doc """
  A standalone, self-contained HTML string of the invoice: embedded stylesheet,
  inlined logo, document layout.

  ## Options

    * `:print_button` — show the "Print / Save as PDF" button (default `true`).
      Off for anything being printed or attached, where a button is either
      invisible or nonsense.
  """
  def generate_html(%Invoice{} = invoice, opts \\ []) do
    invoice = ensure_associations_loaded(invoice)
    {doc, accent, logo} = Templates.document_for(invoice)

    assigns = %{
      doc: doc,
      invoice: invoice,
      accent: accent,
      logo: inline_logo(logo),
      print_button: Keyword.get(opts, :print_button, true)
    }

    rendered = render("document.html", assigns)
    {:safe, iodata} = Phoenix.HTML.html_escape(rendered)
    IO.iodata_to_binary(iodata)
  end

  @doc """
  Reads a stored logo off disk and returns it as a `data:` URI.

  The document is read where `/uploads/logo.png` means nothing, so the bytes
  have to be in the file. An absolute URL, a missing file or anything too large
  to be sensible inline is left alone — a document with a broken image still
  has to render.
  """
  def inline_logo(nil), do: nil

  def inline_logo("/uploads/" <> _rest = path) do
    file = Path.join([:code.priv_dir(:quantum_billing), "static", path])

    with {:ok, %File.Stat{size: size}} when size <= 2_000_000 <- File.stat(file),
         {:ok, contents} <- File.read(file) do
      "data:#{content_type(path)};base64,#{Base.encode64(contents)}"
    else
      _unreadable_or_too_large ->
        Logger.warning("[InvoicePdfGenerator] could not inline logo #{path}")
        path
    end
  end

  def inline_logo(path), do: path

  defp content_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      _other -> "application/octet-stream"
    end
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
  Prints the invoice to a PDF binary.

  Returns `{:ok, pdf}` or `{:error, reason}`. `{:error, :no_renderer}` means no
  headless browser is installed — see `QuantumBillingWeb.InvoiceDoc.PDF` — and
  callers are expected to fall back to the HTML document rather than attach
  something that is not a PDF.
  """
  def generate_pdf(%Invoice{} = invoice, opts \\ []) do
    invoice
    |> generate_html(print_button: false)
    |> PDF.render(opts)
  end

  @doc """
  Whether `generate_pdf/2` can produce anything on this machine.
  """
  def pdf_available?, do: PDF.available?()

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
        <div :if={@print_button} class="no-print" style="margin-bottom: 16px; text-align: right;">
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
