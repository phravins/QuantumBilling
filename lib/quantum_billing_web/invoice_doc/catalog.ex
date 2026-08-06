defmodule QuantumBillingWeb.InvoiceDoc.Catalog do
  @moduledoc """
  The closed vocabulary of an invoice layout: which blocks exist, which options
  each one takes, and which invoice fields they may name.

  ## Everything here is a whitelist

  A layout is data the user authored, so no value out of it may become an atom
  or a map key on trust. `String.to_atom/1` appears nowhere in this pipeline;
  every field name in a layout is looked up in one of the lists below and
  dropped if it is not there. The design pad casts through `cast_block/2` for
  the same reason — a crafted `phx-value` cannot set an option a block does not
  have.

  ## Attribute order is declared, not incidental

  `attrs/1` returns an ordered list, and the serialiser emits attributes in that
  order. Map iteration order would serialise the same document differently
  between runs, which would make the round-trip test meaningless and every
  layout diff unreadable.
  """

  alias QuantumBillingWeb.InvoiceDoc.Block
  alias QuantumBillingWeb.InvoiceDoc.Document

  # Blocks the user may not remove: without them the pad could produce a
  # document that is not an invoice — no line items, no figures, no number.
  @required ~w(items totals invoice_meta)a

  # Blocks that make no sense twice. Everything not listed may repeat, which
  # today means only `divider`.
  @singleton ~w(logo heading company client invoice_meta items totals
                amount_in_words remarks terms signature footer)a

  @item_fields ~w(serial description hsn_sac quantity unit rate tax_rate amount)
  @required_item_fields ~w(description quantity rate amount)
  @total_fields ~w(taxable_value cgst sgst igst cess round_off grand_total)
  @meta_fields ~w(invoice_number invoice_type invoice_date due_date payment_terms
                  place_of_supply status)

  # Element name in the XML <-> block type. Declared both ways rather than
  # derived by string munging, so `invoice-meta` and `amount-in-words` are not
  # special cases handled by a regex.
  @elements [
    {"logo", :logo},
    {"heading", :heading},
    {"company", :company},
    {"client", :client},
    {"invoice-meta", :invoice_meta},
    {"divider", :divider},
    {"items", :items},
    {"totals", :totals},
    {"amount-in-words", :amount_in_words},
    {"remarks", :remarks},
    {"terms", :terms},
    {"signature", :signature},
    {"footer", :footer}
  ]

  @width {:enum, ~w(full half)}
  @align {:enum, ~w(left center right)}

  # {xml attribute, opts key, type, default}. Order here is emit order.
  @attrs %{
    logo: [
      {"width", :width, @width, "half"},
      {"align", :align, @align, "left"},
      {"max-height", :max_height, :integer, 56},
      {"max-width", :max_width, :integer, 200},
      {"fallback", :fallback, {:enum, ~w(mark none)}, "mark"}
    ],
    heading: [
      {"width", :width, @width, "half"},
      {"align", :align, @align, "right"},
      {"size", :size, {:enum, ~w(sm md lg)}, "lg"},
      {"color", :color, {:enum, ~w(accent default)}, "accent"},
      {"text", :text, :string, ""}
    ],
    company: [
      {"width", :width, @width, "half"},
      {"align", :align, @align, "left"},
      {"label", :label, :string, "From"},
      {"show-address", :show_address, :boolean, true},
      {"show-gstin", :show_gstin, :boolean, true},
      {"show-state", :show_state, :boolean, true}
    ],
    client: [
      {"width", :width, @width, "full"},
      {"align", :align, @align, "left"},
      {"label", :label, :string, "Bill To"},
      {"show-address", :show_address, :boolean, true},
      {"show-gstin", :show_gstin, :boolean, true},
      {"show-email", :show_email, :boolean, true},
      {"show-state", :show_state, :boolean, false}
    ],
    invoice_meta: [
      {"width", :width, @width, "half"},
      {"align", :align, @align, "right"}
    ],
    divider: [],
    items: [
      {"width", :width, @width, "full"},
      {"label", :label, :string, ""},
      {"zebra", :zebra, :boolean, false},
      {"border", :border, {:enum, ~w(hairline none)}, "hairline"}
    ],
    totals: [
      {"width", :width, @width, "full"},
      {"align", :align, @align, "right"},
      {"box-width", :box_width, :integer, 280}
    ],
    amount_in_words: [
      {"width", :width, @width, "full"},
      {"align", :align, @align, "left"},
      {"label", :label, :string, "Amount in Words"}
    ],
    remarks: [
      {"width", :width, @width, "half"},
      {"align", :align, @align, "left"},
      {"label", :label, :string, "Remarks"}
    ],
    terms: [
      {"width", :width, @width, "half"},
      {"align", :align, @align, "left"},
      {"label", :label, :string, "Terms & Conditions"}
    ],
    signature: [
      {"width", :width, @width, "full"},
      {"align", :align, @align, "right"},
      {"height", :height, :integer, 64}
    ],
    footer: [
      {"width", :width, @width, "full"},
      {"align", :align, @align, "center"}
    ]
  }

  # Child element attributes, same {xml, key, type, default} shape.
  @column_attrs [
    {"field", :field, :string, nil},
    {"label", :label, :string, ""},
    {"align", :align, @align, "left"},
    {"width", :width, {:enum, ~w(auto grow)}, "auto"},
    {"format", :format, {:enum, ~w(text money percent)}, "text"}
  ]

  @line_attrs [
    {"field", :field, :string, nil},
    {"label", :label, :string, ""},
    {"emphasis", :emphasis, {:enum, ~w(none strong accent)}, "none"},
    {"when", :when, {:enum, ~w(always present non-zero)}, "always"}
  ]

  # Item column presentation. The design pad may relabel a column, but these
  # are what a fresh one starts as, and they are what the legacy bridge
  # reproduces so the rewrite changes nothing on screen.
  @item_defaults %{
    "serial" => %{label: "#", align: "left", format: "text", width: "auto"},
    "description" => %{label: "Item / Description", align: "left", format: "text", width: "grow"},
    "hsn_sac" => %{label: "HSN / SAC", align: "left", format: "text", width: "auto"},
    "quantity" => %{label: "Qty", align: "right", format: "text", width: "auto"},
    "unit" => %{label: "Unit", align: "left", format: "text", width: "auto"},
    "rate" => %{label: "Rate (₹)", align: "right", format: "money", width: "auto"},
    "tax_rate" => %{label: "Tax (%)", align: "right", format: "percent", width: "auto"},
    "amount" => %{label: "Amount (₹)", align: "right", format: "money", width: "auto"}
  }

  @total_defaults %{
    "taxable_value" => %{label: "Taxable Value", emphasis: "none", when: "always"},
    "cgst" => %{label: "CGST", emphasis: "none", when: "always"},
    "sgst" => %{label: "SGST", emphasis: "none", when: "always"},
    "igst" => %{label: "IGST", emphasis: "none", when: "always"},
    "cess" => %{label: "Cess", emphasis: "none", when: "non-zero"},
    "round_off" => %{label: "Round Off", emphasis: "none", when: "always"},
    "grand_total" => %{label: "Grand Total", emphasis: "accent", when: "always"}
  }

  @meta_defaults %{
    "invoice_number" => %{label: "", emphasis: "strong", when: "always"},
    "invoice_type" => %{label: "Type", emphasis: "none", when: "always"},
    "invoice_date" => %{label: "Invoice Date", emphasis: "none", when: "always"},
    "due_date" => %{label: "Due Date", emphasis: "none", when: "always"},
    "payment_terms" => %{label: "Payment Terms", emphasis: "none", when: "present"},
    "place_of_supply" => %{label: "Place of Supply", emphasis: "none", when: "always"},
    "status" => %{label: "Status", emphasis: "none", when: "always"}
  }

  def required, do: @required
  def required?(type), do: type in @required
  def singleton?(type), do: type in @singleton
  def item_fields, do: @item_fields
  def required_item_fields, do: @required_item_fields
  def required_item_field?(field), do: field in @required_item_fields
  def total_fields, do: @total_fields
  def meta_fields, do: @meta_fields
  def types, do: Enum.map(@elements, fn {_name, type} -> type end)
  def attrs(type), do: Map.get(@attrs, type, [])

  @doc "The XML element name for a block type, or `nil` if the type is unknown."
  def element_name(type) do
    Enum.find_value(@elements, fn {name, t} -> if t == type, do: name end)
  end

  @doc "The block type for an XML element name, or `nil` if it is not one of ours."
  def type_for(name) do
    Enum.find_value(@elements, fn {n, type} -> if n == name, do: type end)
  end

  @doc "Which child element a block type holds, or `nil` if it holds none."
  def child_element(:items), do: "column"
  def child_element(:totals), do: "line"
  def child_element(:invoice_meta), do: "line"
  def child_element(_type), do: nil

  @doc "The attribute spec for a block type's children."
  def child_attrs(:items), do: @column_attrs
  def child_attrs(_type), do: @line_attrs

  @doc "The field vocabulary a block type's children may name."
  def child_fields(:items), do: @item_fields
  def child_fields(:totals), do: @total_fields
  def child_fields(:invoice_meta), do: @meta_fields
  def child_fields(_type), do: []

  @doc """
  A fresh child for `type` naming `field`, with that field's usual presentation.

  Returns `nil` for a field outside the block's vocabulary, which is what makes
  this safe to call with a value straight off the wire.
  """
  def new_child(:items, field), do: build_child(@item_defaults, field, :items)
  def new_child(:totals, field), do: build_child(@total_defaults, field, :totals)
  def new_child(:invoice_meta, field), do: build_child(@meta_defaults, field, :invoice_meta)
  def new_child(_type, _field), do: nil

  defp build_child(defaults, field, type) do
    case Map.fetch(defaults, field) do
      {:ok, attrs} when is_map(attrs) ->
        if field in child_fields(type), do: Map.put(attrs, :field, field)

      :error ->
        nil
    end
  end

  @doc """
  A fresh block of `type` with `id`, carrying every option's default.

  Composite blocks come with their full complement of children — a new totals
  box shows every figure, and the user removes what they do not want. Starting
  empty would put a block on the canvas that renders as nothing.
  """
  def new(type, id) do
    if type in types() do
      %Block{
        type: type,
        id: id,
        opts: defaults(type),
        children: default_children(type),
        text: default_text(type)
      }
    end
  end

  @doc "Every option for `type` at its default."
  def defaults(type) do
    type
    |> attrs()
    |> Map.new(fn {_xml, key, _kind, default} -> {key, default} end)
  end

  defp default_children(:items), do: Enum.map(@item_fields, &new_child(:items, &1))

  defp default_children(:totals), do: Enum.map(@total_fields, &new_child(:totals, &1))

  defp default_children(:invoice_meta) do
    # Not every meta field: type and status belong on the screen chrome, not on
    # the printed document, so a fresh block starts with what an invoice head
    # conventionally carries.
    ~w(invoice_number invoice_date due_date payment_terms place_of_supply)
    |> Enum.map(&new_child(:invoice_meta, &1))
  end

  defp default_children(_type), do: []

  defp default_text(:signature), do: "For Your Company"
  defp default_text(:footer), do: ""
  defp default_text(_type), do: nil

  @doc """
  Applies user-supplied params to a block, ignoring anything not in its spec.

  This is the design pad's only route into `opts`, so an option a block does not
  have cannot be set on it however the params arrive.
  """
  def cast_block(%Block{} = block, params) when is_map(params) do
    opts =
      block.type
      |> attrs()
      |> Enum.reduce(block.opts, fn {xml, key, kind, _default}, acc ->
        case Map.fetch(params, xml) do
          {:ok, raw} ->
            case cast_value(raw, kind) do
              {:ok, value} -> Map.put(acc, key, value)
              :error -> acc
            end

          :error ->
            acc
        end
      end)

    %{block | opts: opts, text: cast_text(block, params)}
  end

  defp cast_text(%Block{type: type} = block, params) when type in [:signature, :footer] do
    case Map.fetch(params, "text") do
      {:ok, text} when is_binary(text) -> text
      _other -> block.text
    end
  end

  defp cast_text(%Block{} = block, _params), do: block.text

  @doc """
  Reads an XML attribute value into the type its spec declares.

  Returns `:error` rather than a default for anything unrecognised, so the
  caller decides whether that means "fall back" (parsing) or "ignore"
  (casting from the pad).
  """
  def cast_value(value, {:enum, allowed}) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  def cast_value(value, :string) when is_binary(value), do: {:ok, value}

  def cast_value(value, :boolean) when is_binary(value) do
    case value do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> :error
    end
  end

  def cast_value(value, :boolean) when is_boolean(value), do: {:ok, value}

  def cast_value(value, :integer) when is_integer(value), do: {:ok, value}

  def cast_value(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _other -> :error
    end
  end

  def cast_value(_value, _kind), do: :error

  @doc "Renders a value back to its XML attribute string."
  def dump_value(true, :boolean), do: "true"
  def dump_value(false, :boolean), do: "false"
  def dump_value(value, :integer) when is_integer(value), do: Integer.to_string(value)
  def dump_value(value, _kind) when is_binary(value), do: value
  def dump_value(value, _kind), do: to_string(value)

  # The stock document, in order. Two consecutive halves pack into a row, so
  # this reads as: logo beside the heading, the From block beside the invoice
  # meta, then full-width content down the page.
  #
  # There is deliberately no signature block. This list is what the application
  # printed before layouts became editable, and it has to keep printing exactly
  # that — a signature line nobody asked for would appear on every existing
  # customer's invoices the day this shipped. It is in the palette instead, for
  # anyone who wants one.
  @classic ~w(logo heading company invoice_meta divider client items totals
              amount_in_words remarks terms footer)a

  @doc """
  The stock layout — what a fresh installation prints, and what the pad's
  "reset" restores.
  """
  def classic do
    blocks =
      @classic
      |> Enum.with_index(1)
      |> Enum.map(fn {type, index} -> new(type, "b#{index}") end)

    %Document{version: 1, blocks: blocks}
  end
end
