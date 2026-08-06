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

  # What the palette offers, in the order it offers it. Labels are the user's
  # words for a block, which are not always the element name — `invoice-meta` is
  # "Invoice Details" to anyone who has not read the schema.
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
        <.icon name={icon_for(@block.type)} class="size-3" />
        {label_for(@block.type)}
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

      <%!-- The real thing, not a placeholder: the pad's whole promise is that
      what is on the canvas is what prints. --%>
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
        <%!-- `_id` rather than `id`: a form input named `id` overrides the DOM
        id of the form element it sits in, which LiveView needs to track it. --%>
        <input type="hidden" name="_id" value={@block.id} />

        <.option
          :for={{xml, key, kind, _default} <- Catalog.attrs(@block.type)}
          name={xml}
          label={option_label(xml)}
          kind={kind}
          value={Map.get(@block.opts, key)}
        />

        <label :if={@block.type in [:signature, :footer]} class="block">
          <span class="mb-1 block text-xs text-base-content/60">Text</span>
          <textarea
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
      />
      <span class="text-xs text-base-content/70">{@label}</span>
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

  # Which columns the item table has, or which lines the totals box shows. The
  # required ones render without a remove button rather than erroring on click.
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
        <.icon name="hero-plus" class="size-3" />
        <span class="truncate">{humanise(field)}</span>
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

  @doc """
  The template list shown on Settings → Customization.

  Each card is a real render of the layout at a fraction of its size, so picking
  one to edit does not require remembering which name went with which design.
  """
  attr :templates, :list, required: true
  attr :invoice, :map, required: true
  attr :logo, :string, default: nil

  def template_list(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
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
            data-confirm={"Delete “#{template.name}”? Invoices already issued with it keep the design they were issued with."}
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
