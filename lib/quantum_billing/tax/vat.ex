defmodule QuantumBilling.Tax.VAT do
  @moduledoc """
  VAT totals. Lines are grouped by their rate, and tax is worked out once per
  group on the group's total, so the summary always adds up.

  Zero-rated, exempt, reverse-charge and out-of-scope lines carry no tax but
  still get a row in the breakdown. With tax-inclusive prices a group's net is
  `gross × 10000 / (10000 + rate_bp)`. A reverse-charge invoice charges nothing:
  the customer accounts for the VAT.
  """

  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Money
  alias QuantumBilling.Tax

  @doc """
  The totals for `items`. `ctx` takes `:reverse_charge`, `:prices_include_tax`
  and `:round_to_whole_units`, all false when absent.
  """
  def totals(items, ctx \\ %{}) do
    items = Enum.reject(items, &is_nil/1)
    reverse_charge? = Map.get(ctx, :reverse_charge) == true
    inclusive? = Map.get(ctx, :prices_include_tax) == true

    breakdown =
      items
      |> Enum.group_by(&group_key(&1, reverse_charge?), &InvoiceItem.amount/1)
      |> Enum.map(fn {{name, category, rate_bp}, amounts} ->
        {taxable, tax} = split(Enum.sum(amounts), rate_bp, inclusive?)

        %{
          "name" => name,
          "category" => category,
          "rate_bp" => rate_bp,
          "taxable" => taxable,
          "tax" => tax
        }
      end)
      |> Enum.sort_by(&{-&1["rate_bp"], &1["name"]})

    taxable_value = breakdown |> Enum.map(& &1["taxable"]) |> Enum.sum()
    vat = breakdown |> Enum.map(& &1["tax"]) |> Enum.sum()

    {grand_total, round_off} =
      if Map.get(ctx, :round_to_whole_units) == true,
        do: Money.round_to_rupee(taxable_value + vat),
        else: {taxable_value + vat, 0}

    %{
      total_items: length(items),
      total_quantity:
        Enum.reduce(items, Decimal.new(0), &Decimal.add(Money.quantity(&1.quantity) || 0, &2)),
      taxable_value: taxable_value,
      cgst_amount: 0,
      sgst_amount: 0,
      igst_amount: 0,
      cess_amount: 0,
      vat_amount: vat,
      tax_breakdown: breakdown,
      round_off: round_off,
      grand_total: grand_total
    }
  end

  defp group_key(_item, true), do: {"Reverse charge", "reverse_charge", 0}

  defp group_key(%InvoiceItem{tax_rate_bp: nil}, false), do: {"No VAT", "out_of_scope", 0}

  defp group_key(%InvoiceItem{} = item, false) do
    category = item.tax_category || "standard"
    {item.tax_name || Tax.percent_label(item.tax_rate_bp), category, Tax.effective_bp(item)}
  end

  defp split(gross, 0, _inclusive?), do: {gross, 0}

  defp split(gross, rate_bp, true) do
    net = Money.net_of_tax(gross, rate_bp)
    {net, gross - net}
  end

  defp split(gross, rate_bp, false), do: {gross, Money.tax_bp(gross, rate_bp)}
end
