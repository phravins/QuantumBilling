defmodule QuantumBillingWeb.InvoiceDocument do
  @moduledoc """
  What an invoice document should show, resolved from the organisation's
  customization settings.

  The invoice is rendered twice — on screen by `InvoiceShowLive` in Tailwind, and
  standalone for printing by `InvoicePdfHTML` in inline CSS, because the print
  page deliberately loads none of the app's stylesheet. Those two cannot share
  markup, but they must not disagree about *what* appears. This module is the one
  place that decides, so a setting toggled off vanishes from both or neither.

  `sample/0` builds an unsaved invoice for the settings preview, so the preview
  is driven by the same fields and the same config as the real thing.
  """

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Settings.Organization

  defstruct template: "Classic",
            accent: "#18181b",
            logo: nil,
            heading: nil,
            footer: nil,
            show_hsn: true,
            show_unit: true,
            show_tax_rate: true,
            show_remarks: true,
            show_amount_words: true,
            show_cess: false

  @doc "Resolves the document settings for `organization`."
  def config(%Organization{} = organization) do
    %__MODULE__{
      template: organization.doc_template || "Classic",
      accent: organization.doc_accent_color || "#18181b",
      logo: presence(organization.doc_logo_path),
      heading: presence(organization.doc_heading),
      footer: presence(organization.doc_footer_text),
      show_hsn: organization.doc_show_hsn,
      show_unit: organization.doc_show_unit,
      show_tax_rate: organization.doc_show_tax_rate,
      show_remarks: organization.doc_show_remarks,
      show_amount_words: organization.doc_show_amount_words,
      show_cess: organization.doc_show_cess
    }
  end

  @doc """
  The title printed on the document.

  Falls back to the invoice's own type, so a Credit Note does not announce
  itself as a Tax Invoice just because nobody filled the heading in.
  """
  def heading(%__MODULE__{heading: nil}, %Invoice{} = invoice), do: invoice.invoice_type
  def heading(%__MODULE__{heading: heading}, _invoice), do: heading

  @doc """
  How many columns the item table has, for a row that has to span all of them.

  Four are fixed — the description, quantity, rate and amount are what an
  invoice *is* — plus the serial and whichever optional columns are on.
  """
  def column_count(%__MODULE__{} = config) do
    5 +
      count_true([config.show_hsn, config.show_unit, config.show_tax_rate])
  end

  @doc """
  Whether the cess row should be printed.

  Both the setting and a non-zero figure: an always-zero row teaches the reader
  nothing, and cess is not something most businesses charge.
  """
  def show_cess?(%__MODULE__{show_cess: false}, _invoice), do: false
  def show_cess?(%__MODULE__{}, %Invoice{cess_amount: amount}), do: (amount || 0) > 0

  @doc """
  A representative invoice for the settings preview.

  Not persisted and never saved — it exists so the preview exercises the real
  template with realistic figures instead of an empty shell.
  """
  def sample do
    %Invoice{
      invoice_number: "INV-0042",
      invoice_type: "Tax Invoice",
      invoice_date: ~D[2026-04-18],
      due_date: ~D[2026-05-18],
      payment_terms: "Net 30 Days",
      place_of_supply: "Maharashtra (27)",
      company_name: "Your Company",
      company_address: "221B Example Street\nMumbai - 400001",
      company_gstin: "27AABCA1234A1Z5",
      company_state: "Maharashtra (27)",
      client_name: "Northwind Traders",
      client_gstin: "27AAACN1234C1ZP",
      client_billing_address: "14 Harbour Road\nMumbai - 400002",
      client_email: "accounts@northwind.example",
      client_state: "Maharashtra (27)",
      taxable_value: 24_000,
      cgst_amount: 2_160,
      sgst_amount: 2_160,
      igst_amount: 0,
      cess_amount: 0,
      round_off: 0,
      grand_total: 28_320,
      total_items: 2,
      total_quantity: 3,
      remarks: "Delivered against PO-8842.",
      terms: "Payable within 30 days.",
      status: "Draft",
      items: [
        %InvoiceItem{
          description: "Design retainer",
          hsn_sac: "998311",
          quantity: 1,
          unit: "Nos",
          rate: 18_000,
          tax_rate: 18,
          amount: 18_000,
          position: 0
        },
        %InvoiceItem{
          description: "Support hours",
          hsn_sac: "998313",
          quantity: 2,
          unit: "Hrs",
          rate: 3_000,
          tax_rate: 18,
          amount: 6_000,
          position: 1
        }
      ]
    }
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp count_true(flags), do: Enum.count(flags, & &1)
end
