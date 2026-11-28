defmodule QuantumBillingWeb.InvoiceDoc.ZatcaLayoutTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBillingWeb.InvoiceDoc.Block
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoiceDoc.Renderer
  alias QuantumBillingWeb.InvoiceDoc.ZatcaLayout

  @simplified %Invoice{
    invoice_type: "Tax Invoice",
    tax_regime: "vat",
    company_vat_country: "SA",
    currency: "SAR"
  }
  @standard %{@simplified | client_tax_number: "300000000000003"}

  defp document(blocks),
    do: %Document{version: 1, page: Layout.default_page(), blocks: blocks}

  defp half(%Block{} = block), do: %{block | opts: Map.put(block.opts, :width, "half")}

  defp full(%Block{} = block), do: %{block | opts: Map.put(block.opts, :width, "full")}

  defp types(document), do: Enum.map(document.blocks, & &1.type)

  defp block(document, type), do: Enum.find(document.blocks, &(&1.type == type))

  # Widths spelled out: the heading and terms default to half.
  defp full_design do
    heading = full(Catalog.new(:heading, "h"))
    meta = Catalog.new(:invoice_meta, "m")
    meta = %{meta | children: meta.children ++ [Catalog.new_child(:invoice_meta, "invoice_type")]}

    document([
      %{heading | opts: Map.put(heading.opts, :text, "INVOICE")},
      half(Catalog.new(:company, "c")),
      half(meta),
      Catalog.new(:client, "b"),
      Catalog.new(:items, "i"),
      half(Catalog.new(:amount_in_words, "w")),
      half(Catalog.new(:totals, "t")),
      full(Catalog.new(:terms, "x"))
    ])
  end

  test "the heading reads the ZATCA title, in English and Arabic" do
    simplified = ZatcaLayout.adapt(full_design(), @simplified)
    standard = ZatcaLayout.adapt(full_design(), @standard)

    assert %{text: "Simplified Tax Invoice", text_ar: "فاتورة ضريبية مبسطة"} =
             block(simplified, :heading).opts

    assert %{text: "Tax Invoice", text_ar: "فاتورة ضريبية"} = block(standard, :heading).opts
    assert simplified.bilingual and standard.bilingual
  end

  test "the seller always shows its address and VAT number, the buyer only on a standard invoice" do
    simplified = ZatcaLayout.adapt(full_design(), @simplified)
    standard = ZatcaLayout.adapt(full_design(), @standard)

    assert %{show_address: true, show_gstin: true} = block(simplified, :company).opts
    assert %{show_address: true, show_gstin: true} = block(standard, :client).opts
    assert block(simplified, :client).opts == Catalog.new(:client, "b").opts
  end

  test "the Type line goes, since the title says it" do
    adapted = ZatcaLayout.adapt(full_design(), @simplified)

    fields = Enum.map(block(adapted, :invoice_meta).children, & &1.field)
    refute "invoice_type" in fields
    assert "invoice_number" in fields
  end

  test "the QR code goes after the totals' row, keeping a half-width pair together" do
    adapted = ZatcaLayout.adapt(full_design(), @simplified)

    rows = Renderer.rows(adapted) |> Enum.map(fn row -> Enum.map(row, & &1.type) end)
    index = Enum.find_index(rows, &(:totals in &1))

    assert Enum.at(rows, index) == [:amount_in_words, :totals]
    assert Enum.at(rows, index + 1) == [:zatca_qr]
    assert Enum.at(rows, index + 2) == [:terms]
    assert %{id: "zatca-qr", opts: %{width: "full"}} = block(adapted, :zatca_qr)
  end

  test "a design without them gets a heading, seller, details and, on a standard invoice, buyer" do
    blank = Catalog.preset("blank")

    simplified = ZatcaLayout.adapt(blank, @simplified)
    standard = ZatcaLayout.adapt(blank, @standard)

    # The added heading is half width, so it pairs with the blank preset's
    # details; the seller and buyer follow that row.
    assert types(simplified) == [:heading, :invoice_meta, :company, :items, :totals, :zatca_qr]

    assert types(standard) ==
             [:heading, :invoice_meta, :company, :client, :items, :totals, :zatca_qr]

    # The blank preset's own details block is kept, not duplicated.
    assert Enum.count(standard.blocks, &(&1.type == :invoice_meta)) == 1
    assert %{show_address: true, show_gstin: true} = block(standard, :client).opts
  end

  test "added blocks are full width, so they don't pair with the design's halves" do
    design = document([half(Catalog.new(:client, "b")), Catalog.new(:items, "i")])
    adapted = ZatcaLayout.adapt(design, @simplified)

    for type <- [:company, :invoice_meta] do
      assert block(adapted, type).opts.width == "full"
    end
  end

  test "a design without totals gets the QR code at the end" do
    adapted = ZatcaLayout.adapt(document([Catalog.new(:items, "i")]), @simplified)

    assert List.last(types(adapted)) == :zatca_qr
  end

  test "adapting twice changes nothing more" do
    once = ZatcaLayout.adapt(full_design(), @standard)

    assert ZatcaLayout.adapt(once, @standard) == once
  end

  test "any other invoice comes back unchanged" do
    design = full_design()

    for invoice <- [
          %Invoice{invoice_type: "Tax Invoice", tax_regime: "gst", currency: "INR"},
          %{@simplified | company_vat_country: "AE", currency: "AED"},
          %{@simplified | currency: "USD"},
          %{@simplified | invoice_type: "Quotation"}
        ] do
      assert ZatcaLayout.adapt(design, invoice) == design
    end
  end
end
