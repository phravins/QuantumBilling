defmodule QuantumBillingWeb.InvoicePdfHTML do
  @moduledoc """
  The printable invoice rendered by `InvoicePdfController`.

  Self-contained: the styles are inline rather than pulled from the app
  stylesheet, because this page is meant to survive being printed, saved and
  reopened without the rest of the application around it.
  """
  use QuantumBillingWeb, :html

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBillingWeb.Format
  alias QuantumBillingWeb.InvoiceDocument

  embed_templates "invoice_pdf_html/*"

  @doc "The document's title, from the customization settings or the invoice type."
  defdelegate heading(config, invoice), to: InvoiceDocument

  @doc "Whether the cess row belongs on this document."
  defdelegate show_cess?(config, invoice), to: InvoiceDocument

  @doc "The line total for an item, as shown on the document."
  def line_amount(item), do: item.quantity * item.rate

  @doc "Rupees with two decimals, for the money columns."
  def money(amount), do: Format.rupees(amount, decimals: 2, space: true)

  @doc "Whether CGST/SGST apply rather than IGST."
  def intra_state?(invoice), do: Invoice.intra_state?(invoice)
end
