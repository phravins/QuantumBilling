defmodule QuantumBillingWeb.InvoiceDoc.ArabicLabelsTest do
  use ExUnit.Case, async: true

  alias QuantumBillingWeb.InvoiceDoc.ArabicLabels
  alias QuantumBillingWeb.InvoiceDoc.Catalog

  doctest ArabicLabels, import: true

  test "every default label of a VAT invoice has its Arabic" do
    meta = Catalog.new(:invoice_meta, "m").children
    labels = for %{label: label} <- meta, label != "", do: label

    for label <- labels ++ ["From", "Bill To", "Grand Total", "Taxable Value", "VAT No."] do
      assert ArabicLabels.ar(label), "no Arabic for #{inspect(label)}"
    end
  end

  test "a VAT line reads VAT and its rate, or its rate's name" do
    assert ArabicLabels.ar("VAT 12.5%") == "ضريبة القيمة المضافة 12.5%"
    assert ArabicLabels.ar("VAT Zero-rated") == "ضريبة القيمة المضافة خاضع للنسبة الصفرية"
    assert ArabicLabels.ar("VAT on goods") == nil
  end

  test "a column heading falls back to the labels" do
    assert ArabicLabels.ar("Qty", :column) == "الكمية"
    assert ArabicLabels.ar("Grand Total", :column) == "الإجمالي"
    assert ArabicLabels.ar(nil) == nil
  end
end
