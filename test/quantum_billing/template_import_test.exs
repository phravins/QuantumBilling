defmodule QuantumBilling.TemplateImportTest do
  @moduledoc """
  Designs created from a starter preset or imported from a file. An imported
  file is untrusted: it goes through the same parser and allowlist as a stored
  layout, may not declare a DTD, and cannot point at another business's images.
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.DesignAssets
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Layout

  @foreign "/uploads/" <> String.duplicate("9f", 16) <> ".png"

  describe "create_from_preset/1" do
    test "creates a design named after the preset, and numbers a second one" do
      assert {:ok, first} = Templates.create_from_preset("modern")
      assert {:ok, second} = Templates.create_from_preset("modern")

      assert first.name == "Modern"
      assert second.name == "Modern 2"
      refute first.is_default
      assert Templates.document_of(first) == Catalog.preset("modern")
    end

    test "refuses a key that is not a preset" do
      assert Templates.create_from_preset("nope") == {:error, :unknown_preset}
    end
  end

  describe "import_layout/3" do
    test "an exported design comes back as it was" do
      doc = Catalog.preset("compact")

      assert {:ok, template} = Templates.import_layout(Layout.to_xml(doc), "From the old system")
      assert template.name == "From the old system"
      assert Templates.document_of(template) == doc
    end

    test "refuses a file over the size limit" do
      xml = String.duplicate(" ", Templates.max_import_bytes() + 1)

      assert {:error, message} = Templates.import_layout(xml, "Big")
      assert message =~ "larger"
    end

    test "refuses something that is not a design" do
      assert {:error, _message} = Templates.import_layout("<html><body/></html>", "Page")
      assert {:error, _message} = Templates.import_layout("not xml at all", "Text")
      assert {:error, _message} = Templates.import_layout(<<0xFF, 0xFE, 0x00>>, "Binary")
    end

    test "refuses DOCTYPE and entity declarations" do
      xml = """
      <!DOCTYPE invoice-layout [<!ENTITY x SYSTEM "file:///etc/passwd">]>
      <invoice-layout version="1"><footer>&x;</footer></invoice-layout>
      """

      assert {:error, message} = Templates.import_layout(xml, "Entities")
      assert message =~ "DOCTYPE"
    end

    test "blanks image paths this business does not own" do
      doc = Layout.put_background(Catalog.preset("letterhead"), @foreign)
      block = Catalog.new(:image, "stamp")
      doc = %{doc | blocks: doc.blocks ++ [%{block | opts: %{block.opts | path: @foreign}}]}

      assert {:ok, template} = Templates.import_layout(Layout.to_xml(doc), "Borrowed")

      imported = Templates.document_of(template)
      assert imported.page.background == ""
      assert Layout.asset_paths(imported) == []
    end

    test "keeps image paths this business does own" do
      :ok = DesignAssets.record(@foreign, "background")
      doc = Layout.put_background(Catalog.preset("letterhead"), @foreign)

      assert {:ok, template} = Templates.import_layout(Layout.to_xml(doc), "Ours")
      assert Templates.document_of(template).page.background == @foreign
    end
  end
end
