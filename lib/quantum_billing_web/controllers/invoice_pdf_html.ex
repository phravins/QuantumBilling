defmodule QuantumBillingWeb.InvoicePdfHTML do
  @moduledoc """
  The printable invoice page for `InvoicePdfController`. Self-contained: the
  stylesheet from `InvoiceDoc.Stylesheet` is inlined, not taken from `app.css`.
  """
  use QuantumBillingWeb, :html

  alias QuantumBillingWeb.InvoiceDoc.Renderer

  embed_templates "invoice_pdf_html/*"
end
