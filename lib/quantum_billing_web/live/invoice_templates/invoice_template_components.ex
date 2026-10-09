defmodule QuantumBillingWeb.InvoiceTemplateComponents do
  @moduledoc """
  The design pad's furniture: the palette, the canvas cards, the inspector, and
  the template list that Settings shows.

  None of these draw an invoice. The canvas card is a frame around
  `InvoiceDoc.Renderer.document/1` with `only` set to one block, and the list
  card is a frame around `InvoiceDoc.Renderer.thumbnail/1` — so what a user drags
  and what they see in the list is the same code that prints. A stand-in would
  drift from the document the moment either changed.
  """
  use Phoenix.Component
  use QuantumBillingWeb, :verified_routes

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]

  import QuantumBillingWeb.SharedComponents,
    only: [card: 1, action_button_class: 0, secondary_button_class: 0, row_action_class: 0]

  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Renderer

  @palette [
    {:logo, "Logo", "hero-photo"},
    {:heading, "Heading", "hero-bookmark"},
    {:company, "Your Details", "hero-building-office"},
    {:client, "Bill To", "hero-user"},
    {:invoice_meta, "Invoice Details", "hero-identification"},
    {:divider, "Divider", "hero-minus"},
    {:items, "Item Table", "hero-table-cells"},
    {:totals, "Totals", "hero-calculator"},
    {:amount_in_words, "Amount in Words", "hero-language"},
    {:remarks, "Remarks", "hero-chat-bubble-left"},
    {:terms, "Terms", "hero-document-text"},
    {:signature, "Signature", "hero-pencil"},
    {:footer, "Footer", "hero-bars-3-bottom-left"}
  ]

  @doc "Every block a user can add, with the label and icon the palette shows."
  def palette, do: @palette

  @doc "The user-facing name of a block type."
  def label_for(type) do
    Enum.find_value(@palette, to_string(type), fn {t, label, _icon} ->
      if t == type, do: label
    end)
  end

  @doc "The icon for a block type."
  def icon_for(type) do
    Enum.find_value(@palette, "hero-square-2-stack", fn {t, _label, icon} ->
      if t == type, do: icon
    end)
  end

  @doc """
  The blocks that can still be added.

  Most blocks are singletons — a document with two totals boxes is a mistake, not
  a layout — so the palette shrinks as they are used rather than letting a user
  add a second and wonder why it looks wrong.
  """
  attr :doc, :map, required: true

  def block_palette(assigns) do
    assigns = assign(assigns, :available, available(assigns.doc))

    ~H"""
    <div class="space-y-1">
      <p class="px-1 pb-1 text-2xs font-medium uppercase tracking-wider text-base-content/45">
        Add a block
      </p>

      <button
        :for={{type, label, icon} <- @available}
        type="button"
        phx-click="add_block"
        phx-value-type={type}
        class="flex w-full items-center gap-2 rounded-field px-2 py-1.5 text-left text-sm text-base-content/70 transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name={icon} class="size-4 shrink-0 text-base-content/45" />
        <span class="truncate">{label}</span>
      </button>

      <p :if={@available == []} class="px-1 py-2 text-xs text-base-content/45">
        Every block is already on the page.
      </p>
    </div>
    """
  end

  defp available(doc) do
    Enum.reject(@palette, fn {type, _label, _icon} ->
      Catalog.singleton?(type) and QuantumBillingWeb.InvoiceDoc.Document.has_type?(doc, type)
    end)
  end

  @doc """
  One block on the canvas: the rendered block, wrapped in a selectable card.

  The move buttons are the primary way to reorder — they work from the keyboard,
  which the drag does not. The drag handle is an accelerator on top.
  """
  attr :block, :map, required: true
  attr :doc, :map, required: true
  attr :invoice, :map, required: true
  attr :logo, :string, default: nil
  attr :accent, :string, required: true
  attr :selected, :boolean, default: false
  attr :first, :boolean, default: false
  attr :last, :boolean, default: false

  def canvas_block(assigns) do
    ~H"""
    <div
      id={"block-#{@block.id}"}
      data-block-id={@block.id}
      draggable="true"
      phx-click="select_block"
      phx-value-id={@block.id}
      class={[
        "group relative cursor-pointer rounded-field border px-3 py-2 transition-colors",
        @selected && "border-base-content/30 bg-base-200/40 ring-2 ring-base-content/10",
        !@selected && "border-transparent hover:border-base-300 hover:bg-base-200/30"
      ]}
    >
      <div class="pointer-events-none absolute -top-2 left-2 z-10 hidden items-center gap-1 rounded-field border border-base-300 bg-base-100 px-1.5 py-0.5 text-2xs text-base-content/60 shadow-sm group-hover:flex">
        <.icon name={icon_for(@block.type)} class="size-3" /> {label_for(@block.type)}
      </div>

      <div class="absolute -top-2 right-2 z-10 hidden items-center gap-0.5 rounded-field border border-base-300 bg-base-100 px-0.5 py-0.5 shadow-sm group-hover:flex">
        <span
          class="flex size-6 cursor-grab items-center justify-center text-base-content/45"
          title="Drag to reorder"
        >
          <.icon name="hero-bars-2" class="size-3.5" />
        </span>

        <button
          type="button"
          phx-click="move_block"
          phx-value-id={@block.id}
          phx-value-dir="up"
          disabled={@first}
          class={[row_action_class(), "disabled:opacity-30"]}
          title="Move up"
        >
          <.icon name="hero-arrow-up" class="size-3.5" />
        </button>

        <button
          type="button"
          phx-click="move_block"
          phx-value-id={@block.id}
          phx-value-dir="down"
          disabled={@last}
          class={[row_action_class(), "disabled:opacity-30"]}
          title="Move down"
        >
          <.icon name="hero-arrow-down" class="size-3.5" />
        </button>

        <button
          type="button"
          phx-click="remove_block"
          phx-value-id={@block.id}
          class={[row_action_class(), "hover:text-red-600"]}
          title="Remove"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>

      <div class="pointer-events-none">
        <Renderer.document
          doc={@doc}
          invoice={@invoice}
          accent={@accent}
          logo={@logo}
          only={@block.id}
        />
      </div>
    </div>
    """
  end

  @doc "The options panel for whichever block is selected."
  attr :block, :map, default: nil
  attr :page, :map, required: true

  def inspector(assigns) do
    ~H"""
    <div :if={is_nil(@block)} class="px-1 py-4 text-center">
      <.icon name="hero-cursor-arrow-rays" class="size-5 text-base-content/30" />
      <p class="mt-2 text-xs text-base-content/45">Select a block to change its options.</p>
    </div>

    <div :if={@block} class="space-y-4">
      <div class="flex items-center gap-2 border-b border-base-300 pb-2">
        <.icon name={icon_for(@block.type)} class="size-4 text-base-content/45" />
        <p class="text-sm font-medium">{label_for(@block.type)}</p>
      </div>

      <form id={"block-form-#{@block.id}"} phx-change="update_block" class="space-y-3">
        <%!-- _id, not id: an input named id overrides the form's DOM id. --%>
        <input type="hidden" name="_id" value={@block.id} />
        <.option
          :for={{xml, key, kind, _default} <- Catalog.attrs(@block.type)}
          name={xml}
          label={option_label(xml)}
          kind={kind}
          value={Map.get(@block.opts, key)}
        />
        <label :if={@block.type in [:signature, :footer]} class="block">
          <span class="mb-1 block text-xs text-base-content/60">Text</span> <textarea
            name="text"
            rows="2"
            class="w-full rounded-field border border-base-300 bg-base-100 px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-base-content/10"
          >{@block.text}</textarea>
        </label>
      </form>
      <.children_editor :if={Catalog.child_element(@block.type)} block={@block} />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :kind, :any, required: true
  attr :value, :any, required: true

  defp option(%{kind: :boolean} = assigns) do
    ~H"""
    <label class="flex items-center gap-2">
      <input type="hidden" name={@name} value="false" />
      <input
        type="checkbox"
        name={@name}
        value="true"
        checked={@value == true}
        class="size-3.5 accent-base-content"
      /> <span class="text-xs text-base-content/70">{@label}</span>
    </label>
    """
  end

  defp option(%{kind: {:enum, _values}} = assigns) do
    assigns = assign(assigns, :options, elem(assigns.kind, 1))

    ~H"""
    <label class="block">
      <span class="mb-1 block text-xs text-base-content/60">{@label}</span>
      <select
        name={@name}
        class="w-full rounded-field border border-base-300 bg-base-100 px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-base-content/10"
      >
        <option :for={value <- @options} value={value} selected={value == @value}>{value}</option>
      </select>
    </label>
    """
  end

  defp option(assigns) do
    ~H"""
    <label class="block">
      <span class="mb-1 block text-xs text-base-content/60">{@label}</span>
      <input
        type={if @kind == :integer, do: "number", else: "text"}
        name={@name}
        value={@value}
        class="w-full rounded-field border border-base-300 bg-base-100 px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-base-content/10"
      />
    </label>
    """
  end

  defp option_label(xml) do
    xml |> String.replace("-", " ") |> String.capitalize()
  end

  # Required items render without a remove button.
  attr :block, :map, required: true

  defp children_editor(assigns) do
    assigns =
      assigns
      |> assign(:present, Enum.map(assigns.block.children, & &1.field))
      |> assign(:all, Catalog.child_fields(assigns.block.type))

    ~H"""
    <div class="space-y-1 border-t border-base-300 pt-3">
      <p class="pb-1 text-2xs font-medium uppercase tracking-wider text-base-content/45">
        {if @block.type == :items, do: "Columns", else: "Lines"}
      </p>

      <div
        :for={{field, index} <- Enum.with_index(@present)}
        class="flex items-center gap-1 rounded-field px-1 py-0.5 hover:bg-base-200/60"
      >
        <span class="flex-1 truncate text-xs">{field_label(@block, field)}</span>
        <button
          type="button"
          phx-click="move_child"
          phx-value-field={field}
          phx-value-dir="up"
          disabled={index == 0}
          class={[row_action_class(), "size-5 disabled:opacity-30"]}
        >
          <.icon name="hero-arrow-up" class="size-3" />
        </button>

        <button
          type="button"
          phx-click="move_child"
          phx-value-field={field}
          phx-value-dir="down"
          disabled={index == length(@present) - 1}
          class={[row_action_class(), "size-5 disabled:opacity-30"]}
        >
          <.icon name="hero-arrow-down" class="size-3" />
        </button>

        <span
          :if={@block.type == :items and Catalog.required_item_field?(field)}
          class="flex size-5 items-center justify-center text-base-content/25"
          title="Always shown"
        >
          <.icon name="hero-lock-closed" class="size-3" />
        </span>

        <button
          :if={!(@block.type == :items and Catalog.required_item_field?(field))}
          type="button"
          phx-click="toggle_child"
          phx-value-field={field}
          class={[row_action_class(), "size-5 hover:text-red-600"]}
        >
          <.icon name="hero-x-mark" class="size-3" />
        </button>
      </div>

      <button
        :for={field <- @all -- @present}
        type="button"
        phx-click="toggle_child"
        phx-value-field={field}
        class="flex w-full items-center gap-1.5 rounded-field px-1 py-0.5 text-left text-xs text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="hero-plus" class="size-3" /> <span class="truncate">{humanise(field)}</span>
      </button>
    </div>
    """
  end

  defp field_label(block, field) do
    case Enum.find(block.children, &(&1.field == field)) do
      %{label: label} when is_binary(label) and label != "" -> label
      _blank -> humanise(field)
    end
  end

  defp humanise(field), do: field |> String.replace("_", " ") |> String.capitalize()

  # Only values the layout parser accepts.
  @typefaces [{"sans", "Sans"}, {"serif", "Serif"}, {"mono", "Mono"}]

  @heading_faces [
    {"match", "Same as body"},
    {"sans", "Sans headings"},
    {"serif", "Serif headings"},
    {"mono", "Mono headings"}
  ]

  @spacings [
    {"tight", "hero-bars-4", "Tight line spacing"},
    {"normal", "hero-bars-3", "Normal line spacing"},
    {"relaxed", "hero-bars-2", "Relaxed line spacing"}
  ]

  @weights [
    {"medium", "font-medium", "Medium headings"},
    {"semibold", "font-semibold", "Semibold headings"},
    {"bold", "font-bold", "Bold headings"}
  ]

  @cases [{"upper", "AA", "Uppercase labels"}, {"normal", "Aa", "Sentence-case labels"}]

  @trackings [
    {"tight", "AV", "Tight letter spacing"},
    {"normal", "AV", "Normal letter spacing"},
    {"wide", "A V", "Wide letter spacing"}
  ]

  @heading_scales [
    {"small", "Small headings"},
    {"normal", "Normal headings"},
    {"large", "Large headings"}
  ]

  @block_spacings [
    {"tight", "Tight blocks"},
    {"normal", "Normal blocks"},
    {"relaxed", "Airy blocks"}
  ]

  @densities [
    {"compact", "Compact rows"},
    {"normal", "Normal rows"},
    {"relaxed", "Tall rows"}
  ]

  @heading_colors [
    {"text", "hero-swatch", "Headings in the text colour"},
    {"accent", "hero-sparkles", "Headings in the accent colour"}
  ]

  @doc """
  The text tools: one toolbar over every typographic setting a document has.

  It writes `page[...]` fields named after the XML attributes in
  `InvoiceDoc.Layout.page_attrs/0`, so whichever LiveView mounts it can hand
  the params straight to `Layout.cast_page/2` without knowing what a control
  was. Everything here is a real document setting — there is no styling in the
  toolbar that the printed invoice does not carry.

  ## It belongs to one design, not to the page

  `template_id` is posted with every change, so the toolbar edits the design it
  is drawn inside rather than whichever one happens to be the default. Settings
  gives every design its own; the design pad, which is already looking at a
  single template, gives none and edits the document it holds.

  ## Collapsed by default where there is a list of them

  A design card is not big enough for fifteen controls, so `collapsible` folds
  the toolbar behind a summary of what it is currently set to. The open state is
  the parent's assign rather than a `<details>` element: a re-render after each
  change would put a `<details>` back to its markup value and snap it shut
  mid-edit.
  """
  attr :id, :string, default: "text-tools"
  attr :page, :map, required: true
  attr :template_id, :any, default: nil
  attr :collapsible, :boolean, default: false
  attr :open, :boolean, default: true
  attr :class, :string, default: nil

  def text_tools(assigns) do
    assigns =
      assign(assigns,
        typefaces: @typefaces,
        heading_faces: @heading_faces,
        spacings: @spacings,
        weights: @weights,
        cases: @cases,
        trackings: @trackings,
        heading_scales: @heading_scales,
        block_spacings: @block_spacings,
        densities: @densities,
        heading_colors: @heading_colors
      )

    ~H"""
    <div class={["rounded-box border border-base-300 bg-base-200/60", @class]}>
      <button
        :if={@collapsible}
        type="button"
        phx-click="toggle_text_tools"
        phx-value-id={@template_id}
        aria-expanded={to_string(@open)}
        aria-controls={@id}
        class="flex w-full items-center gap-1.5 rounded-box px-2 py-1.5 text-left text-xs transition-colors hover:bg-base-300/50"
      >
        <.icon
          name="hero-chevron-right"
          class={["size-3.5 shrink-0 text-base-content/45 transition-transform", @open && "rotate-90"]}
        />
        <span class="font-medium">Text tools</span>
        <span class="ml-auto truncate text-2xs text-base-content/50">{summary(@page)}</span>
      </button>

      <form
        :if={@open}
        id={@id}
        phx-change="update_page"
        class={[
          "flex flex-col gap-1.5 p-1.5",
          @collapsible && "border-t border-base-300"
        ]}
      >
        <%!-- Which design this toolbar edits. --%>
        <input :if={@template_id} type="hidden" name="template_id" value={@template_id} />

        <.tool_row label="Body">
          <label class="flex items-center">
            <span class="sr-only">Typeface</span>
            <select name="page[font]" class={tool_select_class()} title="Typeface">
              <option :for={{value, label} <- @typefaces} value={value} selected={value == @page.font}>
                {label}
              </option>
            </select>
          </label>

          <label class="flex items-center">
            <span class="sr-only">Text size</span>
            <select name="page[base-font]" class={tool_select_class()} title="Text size">
              <option :for={size <- 9..16} value={size} selected={size == @page.base_font}>
                {size} pt
              </option>
            </select>
          </label>

          <span class={tool_divider_class()} aria-hidden="true" />

          <%!-- Radios carry the chosen value and stay keyboard accessible behind the sr-only input. --%>
          <fieldset class="flex items-center gap-0.5">
            <legend class="sr-only">Line spacing</legend>
            <.tool_radio
              :for={{value, icon, label} <- @spacings}
              name="page[line-height]"
              value={value}
              checked={value == @page.line_height}
              icon={icon}
              label={label}
            />
          </fieldset>

          <span class={tool_divider_class()} aria-hidden="true" />

          <fieldset class="flex items-center gap-0.5">
            <legend class="sr-only">Letter spacing</legend>
            <.tool_radio
              :for={{value, glyph, label} <- @trackings}
              name="page[letter-spacing]"
              value={value}
              checked={value == @page.letter_spacing}
              glyph={glyph}
              glyph_class={tracking_glyph_class(value)}
              label={label}
            />
          </fieldset>

          <span class={tool_divider_class()} aria-hidden="true" />

          <%!-- Debounced: a colour drag fires on every step, and each change is a write. --%>
          <.tool_color name="page[text-color]" value={@page.text_color} glyph="A" label="Text colour" />

          <.tool_color
            name="page[muted-color]"
            value={@page.muted_color}
            glyph="A"
            glyph_class="opacity-60"
            label="Secondary text colour"
          />

          <span class={tool_divider_class()} aria-hidden="true" />

          <label class="flex items-center">
            <span class="sr-only">Figures</span>
            <select name="page[numerals]" class={tool_select_class()} title="Figures">
              <option value="proportional" selected={@page.numerals == "proportional"}>
                1234 Normal figures
              </option>
              <option value="tabular" selected={@page.numerals == "tabular"}>
                1234 Aligned figures
              </option>
            </select>
          </label>
        </.tool_row>

        <.tool_row label="Headings">
          <label class="flex items-center">
            <span class="sr-only">Heading typeface</span>
            <select name="page[heading-font]" class={tool_select_class()} title="Heading typeface">
              <option
                :for={{value, label} <- @heading_faces}
                value={value}
                selected={value == @page.heading_font}
              >
                {label}
              </option>
            </select>
          </label>

          <label class="flex items-center">
            <span class="sr-only">Heading size</span>
            <select name="page[heading-scale]" class={tool_select_class()} title="Heading size">
              <option
                :for={{value, label} <- @heading_scales}
                value={value}
                selected={value == @page.heading_scale}
              >
                {label}
              </option>
            </select>
          </label>

          <span class={tool_divider_class()} aria-hidden="true" />

          <fieldset class="flex items-center gap-0.5">
            <legend class="sr-only">Heading weight</legend>
            <.tool_radio
              :for={{value, weight, label} <- @weights}
              name="page[heading-weight]"
              value={value}
              checked={value == @page.heading_weight}
              glyph="A"
              glyph_class={weight}
              label={label}
            />
          </fieldset>

          <span class={tool_divider_class()} aria-hidden="true" />

          <fieldset class="flex items-center gap-0.5">
            <legend class="sr-only">Heading colour</legend>
            <.tool_radio
              :for={{value, icon, label} <- @heading_colors}
              name="page[heading-color]"
              value={value}
              checked={value == @page.heading_color}
              icon={icon}
              label={label}
            />
          </fieldset>

          <span class={tool_divider_class()} aria-hidden="true" />

          <fieldset class="flex items-center gap-0.5">
            <legend class="sr-only">Label case</legend>
            <.tool_radio
              :for={{value, glyph, label} <- @cases}
              name="page[label-case]"
              value={value}
              checked={value == @page.label_case}
              glyph={glyph}
              glyph_class="tracking-tight"
              label={label}
            />
          </fieldset>

          <.tool_color
            name="page[label-color]"
            value={@page.label_color}
            glyph="Aa"
            label="Label colour"
          />
        </.tool_row>

        <.tool_row label="Page">
          <label class="flex items-center">
            <span class="sr-only">Paper size</span>
            <select name="page[size]" class={tool_select_class()} title="Paper size">
              <option :for={value <- ~w(A4 Letter)} value={value} selected={value == @page.size}>
                {value}
              </option>
            </select>
          </label>

          <label class="flex items-center">
            <span class="sr-only">Page margin</span>
            <select name="page[margin]" class={tool_select_class()} title="Page margin">
              <option
                :for={value <- ~w(10mm 14mm 18mm 22mm)}
                value={value}
                selected={value == @page.margin}
              >
                {value} margin
              </option>
            </select>
          </label>

          <label class="flex items-center">
            <span class="sr-only">Space between blocks</span>
            <select
              name="page[paragraph-spacing]"
              class={tool_select_class()}
              title="Space between blocks"
            >
              <option
                :for={{value, label} <- @block_spacings}
                value={value}
                selected={value == @page.paragraph_spacing}
              >
                {label}
              </option>
            </select>
          </label>

          <label class="flex items-center">
            <span class="sr-only">Item table rows</span>
            <select name="page[table-density]" class={tool_select_class()} title="Item table rows">
              <option
                :for={{value, label} <- @densities}
                value={value}
                selected={value == @page.table_density}
              >
                {label}
              </option>
            </select>
          </label>

          <button
            type="button"
            phx-click="reset_text"
            phx-value-id={@template_id}
            title="Clear formatting"
            class="ml-auto flex h-7 items-center gap-1.5 rounded-field px-2 text-xs text-base-content/60 transition-colors hover:bg-base-300/60 hover:text-base-content"
          >
            <.icon name="hero-arrow-uturn-left" class="size-3.5" /> Clear formatting
          </button>
        </.tool_row>
      </form>
    </div>
    """
  end

  defp summary(page) do
    [
      page.font |> String.capitalize(),
      "#{page.base_font}pt",
      String.capitalize(page.heading_weight),
      if(page.label_case == "upper", do: "Caps labels", else: "Plain labels")
    ]
    |> Enum.join(" · ")
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp tool_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-1">
      <span class="w-14 shrink-0 pl-1 text-2xs font-medium uppercase tracking-wide text-base-content/45">
        {@label}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :glyph, :string, required: true
  attr :glyph_class, :string, default: nil

  defp tool_color(assigns) do
    ~H"""
    <label
      class="flex h-7 cursor-pointer items-center gap-1.5 rounded-field px-1.5 transition-colors hover:bg-base-300/60"
      title={@label}
    >
      <span class={["text-xs font-semibold text-base-content/70", @glyph_class]}>{@glyph}</span>
      <input
        type="color"
        name={@name}
        value={@value}
        phx-debounce="400"
        aria-label={@label}
        class="h-4 w-6 cursor-pointer rounded-sm border border-base-300 bg-transparent p-0"
      />
    </label>
    """
  end

  # Literal class strings so Tailwind emits them.
  defp tool_select_class do
    "h-7 cursor-pointer rounded-field border border-base-300 bg-base-100 px-1.5 text-xs " <>
      "text-base-content transition-colors hover:border-base-content/30"
  end

  defp tool_divider_class, do: "mx-0.5 h-5 w-px bg-base-300"

  defp tracking_glyph_class("tight"), do: "tracking-tighter"
  defp tracking_glyph_class("wide"), do: "tracking-widest"
  defp tracking_glyph_class(_normal), do: "tracking-normal"

  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :glyph, :string, default: nil
  attr :glyph_class, :string, default: nil

  defp tool_radio(assigns) do
    ~H"""
    <label class="cursor-pointer" title={@label}>
      <input type="radio" name={@name} value={@value} checked={@checked} class="peer sr-only" />
      <span class={[
        "flex size-7 items-center justify-center rounded-field text-xs text-base-content/55",
        "transition-colors hover:bg-base-300/60",
        "peer-checked:bg-base-100 peer-checked:text-base-content peer-checked:shadow-sm",
        "peer-focus-visible:ring-2 peer-focus-visible:ring-base-content/40"
      ]}>
        <.icon :if={@icon} name={@icon} class="size-4" />
        <span :if={@glyph} class={@glyph_class}>{@glyph}</span>
      </span>
      <span class="sr-only">{@label}</span>
    </label>
    """
  end

  @doc """
  The template list shown on Settings → Customization.

  Each card is a real render of the layout at a fraction of its size, so picking
  one to edit does not require remembering which name went with which design.

  The text tools sit inside the card, over the design they set, rather than in
  a section of their own over the design that happens to be the default.
  `open_tools` is the id of the one card whose toolbar is unfolded.
  """
  attr :templates, :list, required: true
  attr :invoice, :map, required: true
  attr :logo, :string, default: nil
  attr :open_tools, :any, default: nil

  def template_list(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
      <.card :for={template <- @templates} padding="p-3" class="flex flex-col">
        <div class="mb-3 overflow-hidden rounded-field border border-base-300 bg-base-100">
          <Renderer.stylesheet doc={template.document} />
          <Renderer.thumbnail
            doc={template.document}
            invoice={@invoice}
            accent={template.accent}
            logo={@logo}
            scale={0.34}
          />
        </div>

        <div class="mb-2 flex items-start justify-between gap-2">
          <p class="min-w-0 flex-1 truncate text-sm font-medium">{template.name}</p>

          <span
            :if={template.is_default}
            class="shrink-0 rounded-field bg-base-200 px-1.5 py-0.5 text-2xs font-medium text-base-content/70"
          >
            Default
          </span>
        </div>

        <.text_tools
          id={"text-tools-#{template.id}"}
          page={template.document.page}
          template_id={template.id}
          collapsible
          open={@open_tools == template.id}
          class="mb-2"
        />

        <div class="mt-auto flex flex-wrap items-center gap-1.5">
          <.link
            navigate={~p"/invoice-templates/#{template.id}"}
            class={[action_button_class(), "h-8 px-2.5 text-xs"]}
          >
            <.icon name="hero-paint-brush" class="size-3.5" /> Design
          </.link>

          <button
            type="button"
            phx-click="duplicate_template"
            phx-value-id={template.id}
            class={[secondary_button_class(), "h-8 px-2.5 text-xs"]}
          >
            Duplicate
          </button>

          <button
            :if={!template.is_default}
            type="button"
            phx-click="set_default_template"
            phx-value-id={template.id}
            class={[secondary_button_class(), "h-8 px-2.5 text-xs"]}
          >
            Make default
          </button>

          <button
            :if={!template.is_default}
            type="button"
            phx-click="delete_template"
            phx-value-id={template.id}
            data-confirm={"Move “#{template.name}” to the Bin? Invoices already issued with it keep the design they were issued with, and it can be restored from there."}
            class={[secondary_button_class(), "h-8 px-2.5 text-xs hover:text-red-600"]}
          >
            Delete
          </button>
        </div>
      </.card>
    </div>
    """
  end
end
