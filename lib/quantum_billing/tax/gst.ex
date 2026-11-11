defmodule QuantumBilling.Tax.GST do
  @moduledoc """
  India GST totals: CGST and SGST within the company's state, IGST otherwise.
  Each line carries a whole-percent slab (`InvoiceItem.tax_rate`).
  """

  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Money

  @doc "The totals for `items`; `intra_state?` picks CGST/SGST or IGST."
  def totals(items, intra_state?) do
    items = Enum.reject(items, &is_nil/1)

    taxable_value = Enum.reduce(items, 0, &(InvoiceItem.amount(&1) + &2))

    total_quantity =
      Enum.reduce(items, Decimal.new(0), &Decimal.add(Money.quantity(&1.quantity) || 0, &2))

    tax = Enum.reduce(items, 0, &(InvoiceItem.tax(&1) + &2))

    {cgst, sgst, igst} =
      if intra_state? do
        cgst = div(tax, 2)
        # Not div(tax, 2) twice: an odd amount would lose a paisa.
        {cgst, tax - cgst, 0}
      else
        {0, 0, tax}
      end

    # No cess rate is entered yet, so this is always zero.
    cess = 0

    # The total is billed in whole rupees; the difference is printed, not lost.
    {grand_total, round_off} = Money.round_to_rupee(taxable_value + cgst + sgst + igst + cess)

    %{
      total_items: length(items),
      total_quantity: total_quantity,
      taxable_value: taxable_value,
      cgst_amount: cgst,
      sgst_amount: sgst,
      igst_amount: igst,
      cess_amount: cess,
      round_off: round_off,
      grand_total: grand_total
    }
  end
end
