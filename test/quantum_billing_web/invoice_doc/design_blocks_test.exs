defmodule QuantumBillingWeb.InvoiceDoc.DesignBlocksTest do
  @moduledoc """
  Presets, the newer blocks and page options. Old layouts must print unchanged,
  and image paths only come from the server, never another business.
  """
  use QuantumBilling.DataCase, async: false

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.CustomFields
  alias QuantumBilling.DesignAssets
  alias QuantumBilling.Settings
  alias QuantumBilling.Uploads
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Extras
  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoiceDoc.Renderer
  alias QuantumBillingWeb.InvoiceDoc.Stylesheet
  alias QuantumBillingWeb.InvoiceDocument

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0>>

  defp render_doc(doc, invoice, extras) do
    render_component(&Renderer.document/1, doc: doc, invoice: invoice, extras: extras)
  end

  # A real stored upload, so the inliner has a file to read.
  defp stored_png do
    source = Path.join(System.tmp_dir!(), "qb-design-#{System.unique_integer([:positive])}.png")
    File.write!(source, @png <> :crypto.strong_rand_bytes(8))
    {:ok, path} = Uploads.store(source, "image/png")
    File.rm(source)
    on_exit(fn -> Uploads.delete(path) end)
    path
  end

  defp with_block(type, opts \\ %{}) do
    block = Catalog.new(type, "x1")
    %Document{blocks: [%{block | opts: Map.merge(block.opts, opts)}]}
  end

  describe "presets" do
    test "every preset builds, validates and survives the file format" do
      for {key, name, _description} <- Catalog.presets() do
        doc = Catalog.preset(key)

        assert %Document{} = doc, "#{key} did not build"
        assert Layout.validate(doc) == :ok, "#{key} does not validate"
        assert Layout.parse!(Layout.to_xml(doc)) == doc, "#{key} changed in the round trip"
        assert Catalog.preset_name(key) == name
      end
    end

    test "an unknown key is not a preset" do
      refute Catalog.preset?("../classic")
      assert Catalog.preset("nope") == nil
    end
  end

  describe "page options" do
    test "round-trip through the XML" do
      doc = Catalog.classic()

      page =
        Map.merge(doc.page, %{
          border: "band",
          watermark: "custom",
          watermark_text: "COPY",
          background_fit: "top",
          background_opacity: "30",
          space_top: "35mm",
          space_bottom: "20mm"
        })

      doc =
        Layout.put_background(
          %{doc | page: page},
          "/uploads/#{String.duplicate("ab", 16)}.png"
        )

      assert Layout.parse!(Layout.to_xml(doc)) == doc
    end

    test "a layout without them prints as it did: no extra rules, no layers" do
      doc = Catalog.classic()
      invoice = InvoiceDocument.sample()

      for mode <- [:screen, :print] do
        refute Stylesheet.css(doc, mode: mode) =~ ".qb-doc--sheet {"
      end

      banded = %{doc | page: %{doc.page | border: "band"}}
      assert Stylesheet.css(banded) =~ ".qb-doc--sheet { border-top: 6px"

      html = render_doc(doc, invoice, Extras.empty())
      refute html =~ "qb-doc__watermark"
      refute html =~ "qb-doc__background"
      refute html =~ "qb-doc--layered"
    end

    test "a form cannot set the background" do
      page =
        Layout.cast_page(Layout.default_page(), %{
          "background" => "/uploads/#{String.duplicate("cd", 16)}.png"
        })

      assert page.background == ""
    end

    test "a form cannot set an image block's path" do
      block = Catalog.new(:image, "i1")

      cast = Catalog.cast_block(block, %{"path" => "/uploads/#{String.duplicate("ef", 16)}.png"})

      assert cast.opts.path == ""
    end

    test "put_background ignores something that is not a stored upload" do
      doc = Layout.put_background(Catalog.classic(), "https://evil.example/x.png")

      assert doc.page.background == ""
    end
  end

  describe "watermark" do
    test "the status watermark marks a draft" do
      doc = Catalog.classic()
      doc = %{doc | page: %{doc.page | watermark: "status"}}

      html = render_doc(doc, InvoiceDocument.sample(), Extras.empty())

      assert html =~ "qb-doc__watermark"
      assert html =~ "DRAFT"
    end

    test "custom text is shown, cut short" do
      doc = Catalog.classic()
      text = String.duplicate("W", 60)
      doc = %{doc | page: %{doc.page | watermark: "custom", watermark_text: text}}

      html = render_doc(doc, InvoiceDocument.sample(), Extras.empty())

      assert html =~ String.duplicate("W", 40)
      refute html =~ String.duplicate("W", 41)
    end
  end

  describe "payment block" do
    setup do
      organization = Settings.get_organization()

      {:ok, organization} =
        Settings.update_section(organization, %{"upi_vpa" => "acme@okhdfcbank"}, :integrations)

      {:ok, organization} =
        Settings.update_section(
          organization,
          %{
            "bank_account_name" => "Acme Traders",
            "bank_name" => "HDFC Bank",
            "bank_account_number" => "5010 0012 3456",
            "bank_ifsc" => "hdfc0001234"
          },
          :invoice
        )

      %{organization: organization}
    end

    test "shows the UPI ID, a QR code and the bank lines", %{organization: organization} do
      doc = with_block(:payment)
      invoice = InvoiceDocument.sample(organization)
      extras = Extras.build(invoice, doc, organization: organization)

      html = render_doc(doc, invoice, extras)

      assert html =~ "acme@okhdfcbank"
      assert html =~ "<svg"
      assert html =~ "HDFC0001234"
      assert html =~ "501000123456"
    end

    test "can leave the QR and bank details out", %{organization: organization} do
      doc = with_block(:payment, %{show_qr: false, show_bank: false})
      invoice = InvoiceDocument.sample(organization)
      extras = Extras.build(invoice, doc, organization: organization)

      html = render_doc(doc, invoice, extras)

      assert html =~ "acme@okhdfcbank"
      refute html =~ "<svg"
      refute html =~ "HDFC0001234"
    end

    test "a page without the block reads nothing" do
      assert Extras.build(InvoiceDocument.sample(), Catalog.classic()) == Extras.empty()
    end
  end

  describe "images" do
    test "this business's background is inlined for print" do
      path = stored_png()
      :ok = DesignAssets.record(path, "background")
      doc = Layout.put_background(Catalog.preset("letterhead"), path)

      extras = Extras.build(InvoiceDocument.sample(), doc, inline: true)

      assert "data:image/png;base64," <> _ = extras.images[path]
      assert render_doc(doc, InvoiceDocument.sample(), extras) =~ "qb-doc__background"
    end

    test "a path the business never recorded is not shown" do
      path = stored_png()
      doc = Layout.put_background(Catalog.preset("letterhead"), path)

      extras = Extras.build(InvoiceDocument.sample(), doc, inline: true)

      assert extras.images == %{}
      refute render_doc(doc, InvoiceDocument.sample(), extras) =~ "qb-doc__background"
    end

    test "an image block shows its recorded stamp" do
      path = stored_png()
      :ok = DesignAssets.record(path, "image")
      block = Catalog.new(:image, "s1")
      doc = %Document{blocks: [%{block | opts: %{block.opts | path: path}}]}

      extras = Extras.build(InvoiceDocument.sample(), doc)

      assert render_doc(doc, InvoiceDocument.sample(), extras) =~ ~s(src="#{path}")
    end
  end

  describe "custom text and spacer" do
    test "custom text renders its title and body, escaped" do
      block = Catalog.new(:custom_text, "t1")

      block = %{
        block
        | text: "Goods once sold <b>are not</b> returned.",
          opts: %{block.opts | title: "Note"}
      }

      html = render_doc(%Document{blocks: [block]}, InvoiceDocument.sample(), Extras.empty())

      assert html =~ "Note"
      assert html =~ "&lt;b&gt;are not&lt;/b&gt;"
    end

    test "a spacer's height is clamped" do
      block = Catalog.new(:spacer, "s1")
      block = %{block | opts: %{block.opts | height: 9_999}}

      html = render_doc(%Document{blocks: [block]}, InvoiceDocument.sample(), Extras.empty())

      assert html =~ "height: 400px"
    end
  end

  describe "custom fields" do
    setup do
      user = owner_fixture()
      business = Businesses.default!()

      scope =
        Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))

      field = fn object, attrs ->
        {:ok, definition} = CustomFields.create_definition(scope, object, attrs)
        definition
      end

      field.("invoice", %{"label" => "PO Number", "type" => "text", "show_on_invoice" => true})
      field.("invoice", %{"label" => "Internal note", "type" => "text"})
      field.("invoice_item", %{"label" => "Batch", "type" => "text", "show_on_invoice" => true})
      :ok
    end

    defp with_values(invoice, values, item_values) do
      items = Enum.map(invoice.items, &%{&1 | custom_fields: item_values})
      %{invoice | custom_fields: values, items: items}
    end

    test "the block prints only the fields marked to show, escaped" do
      doc = with_block(:custom_fields)

      invoice =
        with_values(
          InvoiceDocument.sample(),
          %{"po_number" => "PO-<77>", "internal_note" => "secret"},
          %{}
        )

      html = render_doc(doc, invoice, Extras.build(invoice, doc))

      assert html =~ "PO Number"
      assert html =~ "PO-&lt;77&gt;"
      refute html =~ "secret"
    end

    test "item fields with a value become a column before Amount" do
      doc = Catalog.classic()
      invoice = with_values(InvoiceDocument.sample(), %{}, %{"batch" => "B-12"})

      html = render_doc(doc, invoice, Extras.build(invoice, doc))

      assert html =~ "Batch"
      assert html =~ "B-12"
    end

    test "an old layout with no values prints exactly as before" do
      doc = Catalog.classic()
      invoice = InvoiceDocument.sample()

      assert Extras.build(invoice, doc) == Extras.empty()

      assert render_doc(doc, invoice, Extras.build(invoice, doc)) ==
               render_doc(doc, invoice, Extras.empty())
    end

    test "the block survives the file format" do
      block = Catalog.new(:custom_fields, "cf1")
      block = %{block | opts: %{block.opts | label: "Order"}}
      classic = Catalog.classic()
      doc = %{classic | blocks: classic.blocks ++ [block]}

      assert Layout.validate(doc) == :ok
      assert Layout.parse!(Layout.to_xml(doc)) == doc
    end
  end
end
