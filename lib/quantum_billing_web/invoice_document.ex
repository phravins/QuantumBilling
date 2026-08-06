defmodule QuantumBillingWeb.InvoiceDocument do
  @moduledoc """
  A representative invoice, for previewing a layout without a real one.

  This module used to decide what an invoice document showed, because the
  document was rendered twice from separate markup and something had to keep the
  two honest. That job now belongs to the layout itself: `InvoiceDoc.Layout`
  reads it, `InvoiceDoc.Renderer` renders it, and every surface goes through the
  same component, so there is no longer a pair of markups that could disagree.

  What is left is the fixture. The settings preview and the design pad have no
  invoice to show — they are configuration screens — so they render this one.
  It is deliberately realistic rather than empty: a preview built from blanks
  cannot show whether the column widths work or the totals box fits.
  """

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem

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
end
