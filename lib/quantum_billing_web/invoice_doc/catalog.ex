defmodule QuantumBillingWeb.InvoiceDoc.Catalog do
  @moduledoc """
  The closed vocabulary of an invoice layout: blocks, their options, and the invoice fields they may name.

  Every name in a layout is looked up in these allowlists and dropped if absent;
  nothing becomes an atom. `attrs/1` is ordered, and that is the emit order.
  """

  alias QuantumBillingWeb.InvoiceDoc.Block
  alias QuantumBillingWeb.InvoiceDoc.Document

  # Without these the document would not be an invoice.
  @required ~w(items totals invoice_meta)a

  # Everything else (divider, custom text, spacer, image) may repeat.
  @singleton ~w(logo heading company client invoice_meta items totals
                amount_in_words remarks terms signature footer payment custom_fields)a

  # Set by the server after an upload, never from the pad's params.
  @server_only ~w(path)

  @item_fields ~w(serial description hsn_sac quantity unit rate tax_rate amount)
  @required_item_fields ~w(description quantity rate amount)
  @total_fields ~w(taxable_value cgst sgst igst cess round_off grand_total)
  @meta_fields ~w(invoice_number invoice_type invoice_date due_date payment_terms
                  place_of_supply status)

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
    {"footer", :footer},
    {"custom-text", :custom_text},
    {"spacer", :spacer},
    {"payment", :payment},
    {"image", :image},
    {"custom-fields", :custom_fields}
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
    ],
    custom_text: [
      {"width", :width, @width, "full"},
      {"align", :align, @align, "left"},
      {"title", :title, :string, ""},
      {"style", :style, {:enum, ~w(plain boxed accent)}, "plain"}
    ],
    spacer: [
      {"height", :height, :integer, 24}
    ],
    payment: [
      {"width", :width, @width, "full"},
      {"align", :align, @align, "left"},
      {"label", :label, :string, "Payment Details"},
      {"show-upi", :show_upi, :boolean, true},
      {"show-qr", :show_qr, :boolean, true},
      {"show-bank", :show_bank, :boolean, true},
      {"qr-size", :qr_size, :integer, 96}
    ],
    custom_fields: [
      {"width", :width, @width, "half"},
      {"align", :align, @align, "left"},
      {"label", :label, :string, "Details"}
    ],
    image: [
      {"width", :width, @width, "full"},
      {"align", :align, @align, "left"},
      {"max-height", :max_height, :integer, 80},
      {"path", :path, :upload, ""}
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

  @item_defaults %{
    "serial" => %{label: "S.No", align: "left", format: "text", width: "auto"},
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
  A fresh child for `type` naming `field`, or `nil` for a field outside the block's vocabulary.
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
  A fresh block of `type` with `id` and default options. Composite blocks start with every child.
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
    # Type and status are screen chrome, not printed.
    ~w(invoice_number invoice_date due_date payment_terms place_of_supply)
    |> Enum.map(&new_child(:invoice_meta, &1))
  end

  defp default_children(_type), do: []

  defp default_text(:signature), do: "For Your Company"
  defp default_text(:footer), do: ""
  defp default_text(:custom_text), do: "Add your own text here."
  defp default_text(_type), do: nil

  @doc "Block types whose element body is text (the footer copy, a caption)."
  def text_types, do: [:signature, :footer, :custom_text]

  @doc """
  Applies user params to a block, ignoring anything not in its spec. The pad's only route into `opts`.
  """
  def cast_block(%Block{} = block, params) when is_map(params) do
    opts =
      block.type
      |> attrs()
      |> Enum.reject(fn {xml, _key, _kind, _default} -> xml in @server_only end)
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

  defp cast_text(%Block{type: type} = block, params)
       when type in [:signature, :footer, :custom_text] do
    case Map.fetch(params, "text") do
      {:ok, text} when is_binary(text) -> text
      _other -> block.text
    end
  end

  defp cast_text(%Block{} = block, _params), do: block.text

  @doc """
  Reads an XML attribute value into its declared type, or `:error` for anything unrecognised.
  """
  def cast_value(value, {:enum, allowed}) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  def cast_value(value, :string) when is_binary(value), do: {:ok, value}

  # A stored upload's path, or blank. Shape only; ownership is checked by `DesignAssets.owned?/1`.
  def cast_value("", :upload), do: {:ok, ""}

  def cast_value(value, :upload) when is_binary(value) do
    if QuantumBilling.DesignAssets.path?(value), do: {:ok, value}, else: :error
  end

  # Interpolated into the stylesheet, so six hex digits only.
  def cast_value(value, :color) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    if Regex.match?(~r/^#[0-9a-f]{6}$/, value), do: {:ok, value}, else: :error
  end

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

  # The stock document. Consecutive halves pack into a row; no signature block.
  @classic ~w(logo heading company invoice_meta divider client items totals
              amount_in_words remarks terms footer)a

  @doc """
  The stock layout: what a fresh installation prints and what "reset" restores.
  """
  def classic, do: build(@classic)

  # Presets

  @presets [
    {"blank", "Blank", "Only what an invoice must have. Build up from there."},
    {"classic", "Classic", "The standard layout: logo, details, items, totals."},
    {"modern", "Modern", "An accent band, bold headings, striped rows and payment details."},
    {"minimal", "Minimal", "Quiet type, no rules, sentence-case labels."},
    {"compact", "Compact", "Tighter type and rows, so long invoices fit on fewer pages."},
    {"letterhead", "Letterhead", "Leaves room for your printed or uploaded letterhead."}
  ]

  @doc "The starter designs, as `{key, name, description}`."
  def presets, do: @presets

  @doc "Whether `key` names a preset. The gallery's value comes off the wire."
  def preset?(key), do: Enum.any?(@presets, fn {k, _name, _desc} -> k == key end)

  @doc "The preset's display name."
  def preset_name(key) do
    Enum.find_value(@presets, "Design", fn {k, name, _desc} -> if k == key, do: name end)
  end

  @doc "The document a preset starts from, or `nil` for an unknown key."
  def preset("blank"), do: build(~w(invoice_meta items totals)a)
  def preset("classic"), do: classic()

  def preset("modern") do
    ~w(logo heading company invoice_meta client items totals amount_in_words payment
       terms signature footer)a
    |> build(%{
      border: "band",
      heading_weight: "bold",
      heading_color: "accent",
      numerals: "tabular"
    })
    |> update_blocks(:heading, &put_opts(&1, size: "lg", color: "accent"))
    |> update_blocks(:client, &put_opts(&1, width: "half"))
    |> update_blocks(:items, &put_opts(&1, zebra: true))
    |> update_blocks(:payment, &put_opts(&1, width: "half"))
    |> update_blocks(:terms, &put_opts(&1, width: "half"))
  end

  def preset("minimal") do
    ~w(heading invoice_meta company client items totals remarks footer)a
    |> build(%{label_case: "normal", heading_scale: "small", heading_weight: "medium"})
    |> update_blocks(:heading, &put_opts(&1, align: "left", color: "default", size: "md"))
    |> update_blocks(:invoice_meta, &put_opts(&1, align: "left", width: "full"))
    |> update_blocks(:company, &put_opts(&1, label: "From"))
    |> update_blocks(:client, &put_opts(&1, width: "half"))
    |> update_blocks(:items, &put_opts(&1, border: "none"))
  end

  def preset("compact") do
    ~w(logo heading company invoice_meta client items totals amount_in_words terms footer)a
    |> build(%{
      table_density: "compact",
      paragraph_spacing: "tight",
      base_font: 11,
      margin: "10mm",
      line_height: "tight"
    })
    |> update_blocks(:logo, &put_opts(&1, max_height: 40))
    |> update_blocks(:client, &put_opts(&1, width: "half"))
    |> update_blocks(:terms, &put_opts(&1, width: "full"))
  end

  def preset("letterhead") do
    ~w(heading invoice_meta client items totals amount_in_words payment terms signature)a
    |> build(%{space_top: "35mm", space_bottom: "20mm"})
    |> update_blocks(:heading, &put_opts(&1, align: "left", size: "lg"))
    |> update_blocks(:invoice_meta, &put_opts(&1, align: "right"))
    |> update_blocks(:client, &put_opts(&1, width: "half"))
    |> update_blocks(:payment, &put_opts(&1, width: "half"))
    |> update_blocks(:terms, &put_opts(&1, width: "half"))
  end

  def preset(_key), do: nil

  defp build(types, page \\ %{}) do
    blocks =
      types
      |> Enum.with_index(1)
      |> Enum.map(fn {type, index} -> new(type, "b#{index}") end)

    document = %Document{version: 1, blocks: blocks}
    %{document | page: Map.merge(document.page, page)}
  end

  defp update_blocks(%Document{} = document, type, fun) do
    %{document | blocks: Enum.map(document.blocks, &if(&1.type == type, do: fun.(&1), else: &1))}
  end

  defp put_opts(%Block{} = block, opts), do: %{block | opts: Map.merge(block.opts, Map.new(opts))}
end
