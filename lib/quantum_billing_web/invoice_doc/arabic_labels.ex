defmodule QuantumBillingWeb.InvoiceDoc.ArabicLabels do
  @moduledoc """
  Arabic for the invoice document's default labels, for a Saudi invoice,
  which ZATCA requires in Arabic (it may be bilingual).

  Keyed by the English default exactly as the renderer prints it. A label the
  business has rewritten finds no key and prints as written: a guessed
  translation would be worse than none.
  """

  @labels %{
    # Block labels
    "From" => "البائع",
    "Bill To" => "المشتري",
    "Amount in Words" => "المبلغ كتابةً",
    "Remarks" => "ملاحظات",
    "Terms & Conditions" => "الشروط والأحكام",
    "Payment Details" => "تفاصيل الدفع",
    "Details" => "تفاصيل",
    "VAT No." => "الرقم الضريبي",

    # Details lines
    "Invoice Date" => "تاريخ الفاتورة",
    "Due Date" => "تاريخ الاستحقاق",
    "Payment Terms" => "شروط الدفع",
    "Place of Supply" => "مكان التوريد",
    "Type" => "النوع",
    "Status" => "الحالة",

    # Totals
    "Taxable Value" => "المبلغ الخاضع للضريبة",
    "VAT" => "ضريبة القيمة المضافة",
    "Round Off" => "التقريب",
    "Grand Total" => "الإجمالي",
    "VAT (reverse charge)" => "ضريبة القيمة المضافة (احتساب عكسي)",

    # VAT summary
    "VAT summary" => "ملخص الضريبة",
    "Taxable amount" => "المبلغ الخاضع للضريبة",

    # Saudi VAT rates, as the VAT summary names them
    "Standard 15%" => "النسبة الأساسية 15%",
    "Zero-rated" => "خاضع للنسبة الصفرية",
    "Exempt" => "معفى"
  }

  # Item table headings. "VAT" heads the rate column here, not the amount.
  @columns %{
    "S.No" => "م",
    "Item / Description" => "الصنف / الوصف",
    "Item Code" => "رمز الصنف",
    "Qty" => "الكمية",
    "Unit" => "الوحدة",
    "Rate (₹)" => "سعر الوحدة",
    "VAT" => "نسبة الضريبة",
    "Amount (₹)" => "المبلغ",
    "VAT amount" => "مبلغ الضريبة",
    "Total incl. VAT" => "المجموع شامل الضريبة"
  }

  @vat_prefix "VAT "

  @doc """
  The Arabic for the default label `text`, or `nil`.

  `context` is `:label` (default) or `:column` for an item table heading. A
  totals line such as "VAT 15%" is translated as VAT plus its rate.

      iex> ar("Grand Total")
      "الإجمالي"

      iex> ar("VAT", :column)
      "نسبة الضريبة"

      iex> ar("VAT 15%")
      "ضريبة القيمة المضافة 15%"

      iex> ar("Billed to")
      nil
  """
  def ar(text, context \\ :label)

  def ar(text, :column) when is_binary(text), do: Map.get(@columns, text) || ar(text, :label)

  def ar(text, :label) when is_binary(text) do
    case Map.fetch(@labels, text) do
      {:ok, arabic} -> arabic
      :error -> vat_line(text)
    end
  end

  def ar(_text, _context), do: nil

  defp vat_line(@vat_prefix <> rest) do
    cond do
      Regex.match?(~r/^\d+(\.\d+)?%$/, rest) -> @labels["VAT"] <> " " <> rest
      arabic = Map.get(@labels, rest) -> @labels["VAT"] <> " " <> arabic
      true -> nil
    end
  end

  defp vat_line(_text), do: nil
end
