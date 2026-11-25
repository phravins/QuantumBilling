defmodule QuantumBillingWeb.InvoiceDoc.QuotationLayoutTest do
  use ExUnit.Case, async: true

  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoiceDoc.QuotationLayout

  defp document(blocks, page_over \\ %{}) do
    %Document{version: 1, page: Map.merge(Layout.default_page(), page_over), blocks: blocks}
  end

  defp types(document), do: Enum.map(document.blocks, & &1.type)

  test "drops the payment block and keeps custom fields" do
    adapted =
      [
        Catalog.new(:heading, "h"),
        Catalog.new(:items, "i"),
        Catalog.new(:payment, "p"),
        Catalog.new(:custom_fields, "c")
      ]
      |> document()
      |> QuotationLayout.adapt()

    assert types(adapted) == [:heading, :items, :custom_fields]
  end

  test "blanks the heading so it reads the document type, Quotation" do
    heading = %{
      Catalog.new(:heading, "h")
      | opts: Map.put(Catalog.defaults(:heading), :text, "TAX INVOICE")
    }

    assert [%{opts: %{text: ""}}] = QuotationLayout.adapt(document([heading])).blocks
  end

  test "adds a heading to a design that has none" do
    adapted = QuotationLayout.adapt(document([Catalog.new(:items, "i")]))
    assert types(adapted) == [:heading, :items]
  end

  test "relabels the dates and drops payment terms" do
    [_heading, meta] = QuotationLayout.adapt(document([Catalog.new(:invoice_meta, "m")])).blocks

    labels = Map.new(meta.children, &{&1.field, &1.label})

    assert labels["invoice_date"] == "Quotation Date"
    assert labels["due_date"] == "Valid Until"
    refute Map.has_key?(labels, "payment_terms")
  end

  test "turns off a status watermark but keeps a custom one" do
    status = QuotationLayout.adapt(document([], %{watermark: "status"}))
    custom = QuotationLayout.adapt(document([], %{watermark: "custom"}))

    assert status.page.watermark == "none"
    assert custom.page.watermark == "custom"
  end
end
