defmodule QuantumBilling.GSTParityTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Tax.GST

  test "odd paisa intra-state tax has equal heads and preserves the total" do
    totals = GST.totals([%{quantity: 1, rate: 55_561, tax_rate: 18}], true)

    assert totals.cgst_amount == totals.sgst_amount
    assert totals.grand_total == 65_600

    assert totals.taxable_value + totals.cgst_amount + totals.sgst_amount + totals.round_off ==
             totals.grand_total
  end

  test "inter-state tax stays in IGST" do
    totals = GST.totals([%{quantity: 1, rate: 55_561, tax_rate: 18}], false)

    assert totals.cgst_amount == 0
    assert totals.sgst_amount == 0
    assert totals.igst_amount == 10_001
  end
end
