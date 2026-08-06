defmodule QuantumBillingWeb.InvoiceDoc.LayoutTest do
  @moduledoc """
  The layout XML is the format a user's invoice design is stored in, so the
  round trip has to be exact: anything the serialiser drops is a design the
  customer loses, silently, on the next save.
  """
  use ExUnit.Case, async: true

  alias QuantumBillingWeb.InvoiceDoc.Block
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Layout

  describe "round trip" do
    # Byte identity holds only because `to_xml/1` emits attributes in the order
    # `Catalog.attrs/1` declares rather than map order, and writes every option
    # whether or not it differs from its default. That is what makes a save
    # that changed nothing a no-op instead of a spurious diff.
    test "serialising a parsed layout returns the identical string" do
      xml = Layout.to_xml(Catalog.classic())

      assert xml |> Layout.parse!() |> Layout.to_xml() == xml
    end

    test "the stock layout survives with every block and child intact" do
      original = Catalog.classic()
      parsed = original |> Layout.to_xml() |> Layout.parse!()

      assert Enum.map(parsed.blocks, & &1.type) == Enum.map(original.blocks, & &1.type)
      assert Enum.map(parsed.blocks, & &1.id) == Enum.map(original.blocks, & &1.id)
      assert parsed.page == original.page
      assert parsed.version == original.version

      for {a, b} <- Enum.zip(parsed.blocks, original.blocks) do
        assert a.opts == b.opts, "options differ on #{a.type}"
        assert a.children == b.children, "children differ on #{a.type}"
        assert a.text == b.text, "text differs on #{a.type}"
      end
    end

    test "a reordered layout keeps the new order" do
      original = Catalog.classic()
      reordered = %{original | blocks: Enum.reverse(original.blocks)}

      parsed = reordered |> Layout.to_xml() |> Layout.parse!()

      assert Enum.map(parsed.blocks, & &1.id) == Enum.map(reordered.blocks, & &1.id)
    end

    test "every block type round-trips with its options set away from the defaults" do
      blocks =
        Catalog.types()
        |> Enum.with_index(1)
        |> Enum.map(fn {type, index} ->
          block = Catalog.new(type, "b#{index}")
          %{block | opts: Map.new(block.opts, fn {k, v} -> {k, flip(v)} end)}
        end)

      document = %Document{blocks: blocks}
      parsed = document |> Layout.to_xml() |> Layout.parse!()

      for {a, b} <- Enum.zip(parsed.blocks, blocks) do
        assert a.opts == b.opts, "#{a.type} lost an option in the round trip"
      end
    end
  end

  describe "escaping" do
    # Saxy escapes text passed as a `{:characters, _}` node but emits a raw
    # binary child verbatim, which would produce a layout nothing can parse.
    # This is the test that catches that mistake being reintroduced.
    test "markup characters in element content survive" do
      text = ~s|Smith & Sons <"quoted"> 'apostrophe'|

      assert round_trip_footer(text) == text
    end

    test "newlines in element content survive" do
      text = "Line one\nLine two\n\nLine four"

      assert round_trip_footer(text) == text
    end

    test "markup characters in an attribute survive" do
      document = put_label(Catalog.classic(), :client, ~s|Bill To <A & B> "Ltd"|)

      parsed = document |> Layout.to_xml() |> Layout.parse!()

      assert label_of(parsed, :client) == ~s|Bill To <A & B> "Ltd"|
    end

    defp round_trip_footer(text) do
      document =
        Layout.parse!(
          Layout.to_xml(update_block(Catalog.classic(), :footer, &%{&1 | text: text}))
        )

      Enum.find(document.blocks, &(&1.type == :footer)).text
    end
  end

  describe "parsing hostile or unfamiliar input" do
    # This is the property Saxy was chosen for. `:xmerl` expands internal
    # entities by default, which is how a small document becomes a very large
    # one; Saxy has no DTD support at all, so the entity is never expanded.
    test "an internal entity is not expanded" do
      xml = """
      <?xml version="1.0"?>
      <!DOCTYPE invoice-template [<!ENTITY boom "expanded">]>
      <invoice-template version="1">
        <blocks><footer id="b1" width="full" align="center">&boom;</footer></blocks>
      </invoice-template>
      """

      {:ok, document} = Layout.parse(xml)
      footer = Enum.find(document.blocks, &(&1.type == :footer))

      refute footer.text =~ "expanded"
    end

    test "a newer schema version is refused by name" do
      xml = String.replace(Layout.to_xml(Catalog.classic()), ~s|version="1"|, ~s|version="9"|)

      assert {:error, message} = Layout.parse(xml)
      assert message =~ "newer version"
    end

    test "malformed XML returns an error rather than raising" do
      assert {:error, message} = Layout.parse("<invoice-template><blocks>")
      assert message =~ "not valid XML"
    end

    test "a different document is refused" do
      assert {:error, message} = Layout.parse(~s|<?xml version="1.0"?><catalogue/>|)
      assert message =~ "not an invoice layout"
    end

    # Dropping rather than failing: a layout that has lost one block is still a
    # usable invoice, whereas refusing to parse would take a customer's document
    # off the screen over an attribute nobody recognises.
    test "an unknown block element is dropped" do
      xml = inject(~s|<hologram id="b99" width="full"/>|)

      {:ok, document} = Layout.parse(xml)

      assert Enum.map(document.blocks, & &1.type) == Enum.map(Catalog.classic().blocks, & &1.type)
    end

    test "an unknown column field is dropped and the rest of the table survives" do
      xml =
        String.replace(
          Layout.to_xml(Catalog.classic()),
          ~s|<column field="serial"|,
          ~s|<column field="nonsense" label="X" align="left" width="auto" format="text"/>\n      <column field="serial"|
        )

      {:ok, document} = Layout.parse(xml)
      items = Enum.find(document.blocks, &(&1.type == :items))

      assert Enum.map(items.children, & &1.field) == Catalog.item_fields()
    end

    test "an unknown option value falls back to the default rather than being stored" do
      xml =
        String.replace(Layout.to_xml(Catalog.classic()), ~s|align="right"|, ~s|align="sideways"|)

      {:ok, document} = Layout.parse(xml)

      for block <- document.blocks do
        assert block.opts[:align] in [nil, "left", "center", "right"]
      end
    end

    test "duplicate ids are reassigned so the pad can address each block" do
      xml = String.replace(Layout.to_xml(Catalog.classic()), ~r/id="b\d+"/, ~s|id="same"|)

      {:ok, document} = Layout.parse(xml)
      ids = Document.ids(document)

      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  describe "validate/1" do
    test "the stock layout is valid" do
      assert Layout.validate(Catalog.classic()) == :ok
    end

    test "a layout without an item table is refused" do
      document = drop_type(Catalog.classic(), :items)

      assert {:error, errors} = Layout.validate(document)
      assert Enum.any?(errors, &(&1 =~ "items"))
    end

    test "an item table without its description column is refused" do
      document =
        update_block(Catalog.classic(), :items, fn block ->
          %{block | children: Enum.reject(block.children, &(&1.field == "description"))}
        end)

      assert {:error, errors} = Layout.validate(document)
      assert Enum.any?(errors, &(&1 =~ "description"))
    end
  end

  # The bridge that lets the renderer replace three hand-written markups without
  # changing anybody's invoice. Each of the old booleans has to come out as the
  # presence or absence of exactly one block or column.
  describe "from_legacy/1" do
    # The stock layout carries a footer block for the pad to type into, but an
    # organisation with no footer text has never printed one — so the bridge
    # drops it rather than introducing a rule nobody asked for.
    test "an untouched organisation produces the stock layout, less the empty footer" do
      document = Layout.from_legacy(organization())

      expected = Enum.map(Catalog.classic().blocks, & &1.type) -- [:footer]
      assert Enum.map(document.blocks, & &1.type) == expected
    end

    test "each column toggle removes exactly its own column" do
      for {field, key} <- [
            {"hsn_sac", :doc_show_hsn},
            {"unit", :doc_show_unit},
            {"tax_rate", :doc_show_tax_rate}
          ] do
        document = Layout.from_legacy(organization(%{key => false}))
        items = Enum.find(document.blocks, &(&1.type == :items))
        fields = Enum.map(items.children, & &1.field)

        refute field in fields, "#{key} left #{field} on the table"
        assert length(fields) == length(Catalog.item_fields()) - 1
      end
    end

    test "the block toggles remove their blocks" do
      for {type, key} <- [
            {:amount_in_words, :doc_show_amount_words},
            {:remarks, :doc_show_remarks}
          ] do
        document = Layout.from_legacy(organization(%{key => false}))

        refute Document.has_type?(document, type), "#{key} left the #{type} block in place"
      end
    end

    # The old rule was that cess needed both the setting and a non-zero figure.
    # Off removes the line; on keeps it conditional rather than always printed.
    test "cess off removes the line, cess on leaves it conditional" do
      off = Layout.from_legacy(organization(%{doc_show_cess: false}))
      refute "cess" in total_fields(off)

      on = Layout.from_legacy(organization(%{doc_show_cess: true}))
      assert "cess" in total_fields(on)

      line = on |> totals() |> Enum.find(&(&1.field == "cess"))
      assert line.when == "non-zero"
    end

    test "a heading and a footer carry across, and a blank footer drops the block" do
      document =
        Layout.from_legacy(
          organization(%{doc_heading: "ORIGINAL FOR RECIPIENT", doc_footer_text: "Thank you."})
        )

      assert heading_text(document) == "ORIGINAL FOR RECIPIENT"
      assert Enum.find(document.blocks, &(&1.type == :footer)).text == "Thank you."

      refute Document.has_type?(Layout.from_legacy(organization()), :footer)
    end

    test "the result is always serialisable and valid" do
      document = Layout.from_legacy(organization(%{doc_show_hsn: false, doc_show_remarks: false}))

      assert Layout.validate(document) == :ok
      assert document |> Layout.to_xml() |> Layout.parse!() |> Layout.validate() == :ok
    end
  end

  # -- helpers --------------------------------------------------------------

  # A plain map, which is what `from_legacy/1` takes: the columns these describe
  # have been dropped, and the only caller left is the migration that dropped
  # them, which reads them with raw SQL because no struct declares them any more.
  defp organization(overrides \\ %{}) do
    Map.merge(
      %{
        doc_show_hsn: true,
        doc_show_unit: true,
        doc_show_tax_rate: true,
        doc_show_remarks: true,
        doc_show_amount_words: true,
        doc_show_cess: false
      },
      overrides
    )
  end

  defp update_block(%Document{} = document, type, fun) do
    %{document | blocks: Enum.map(document.blocks, &if(&1.type == type, do: fun.(&1), else: &1))}
  end

  defp drop_type(%Document{} = document, type) do
    %{document | blocks: Enum.reject(document.blocks, &(&1.type == type))}
  end

  defp put_label(document, type, label) do
    update_block(document, type, fn %Block{} = b ->
      %{b | opts: Map.put(b.opts, :label, label)}
    end)
  end

  defp label_of(document, type) do
    Enum.find(document.blocks, &(&1.type == type)).opts.label
  end

  defp totals(document), do: Enum.find(document.blocks, &(&1.type == :totals)).children
  defp total_fields(document), do: Enum.map(totals(document), & &1.field)

  defp heading_text(document) do
    Enum.find(document.blocks, &(&1.type == :heading)).opts.text
  end

  defp inject(element) do
    String.replace(Layout.to_xml(Catalog.classic()), "  </blocks>", "  #{element}\n  </blocks>")
  end

  # Moves a value off its default so the round trip has something to lose.
  defp flip(true), do: false
  defp flip(false), do: true
  defp flip(value) when is_integer(value), do: value + 7
  defp flip("full"), do: "half"
  defp flip("half"), do: "full"
  defp flip("left"), do: "right"
  defp flip("right"), do: "center"
  defp flip("center"), do: "left"
  defp flip("lg"), do: "sm"
  defp flip("accent"), do: "default"
  defp flip("mark"), do: "none"
  defp flip("hairline"), do: "none"
  defp flip(value) when is_binary(value), do: value <> " changed"
end
