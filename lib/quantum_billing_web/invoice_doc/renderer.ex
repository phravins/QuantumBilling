defmodule QuantumBillingWeb.InvoiceDoc.Renderer do
  @moduledoc """
  Renders an invoice from its layout.

  This is the only markup for the invoice document. The on-screen page, the
  standalone print page, the settings thumbnail and the design pad's canvas all
  render through here, so none of them can drift from the others — which is what
  the three hand-written copies this replaces could not promise.

  Styling comes from `InvoiceDoc.Stylesheet`, injected as a `<style>` tag by
  whichever surface is rendering. Nothing here carries Tailwind classes: the
  print page has no access to them.

  ## What the layout does not get to decide

  Three rules are applied here regardless of what the XML says, because they are
  matters of law rather than taste:

    * CGST and SGST print only on an intra-state supply, IGST only on an
      inter-state one. A layout cannot put IGST on an intra-state invoice.
    * A `non-zero` line is suppressed when its figure is zero — an always-empty
      cess row teaches the reader nothing.
    * An empty heading falls back to the invoice's own type, so a Credit Note
      does not announce itself as a Tax Invoice because nobody filled the field.
  """
  use Phoenix.Component

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBillingWeb.Format
  alias QuantumBillingWeb.InvoiceDoc.Block
  alias QuantumBillingWeb.InvoiceDoc.Document

  attr :doc, Document, required: true
  attr :mode, :atom, default: :screen, values: [:screen, :print]

  @doc """
  The document's stylesheet, in a `<style>` tag.

  Every surface renders this next to the document.

  The whole tag is built as a safe value rather than written as `<style>` markup
  with the CSS interpolated: HEEx does not interpolate inside a `<style>` element
  at all — it emits `{...}` as literal text — and escaping the CSS as ordinary
  content would turn the child combinator in `.qb-doc__row > .qb-doc__cell` into
  `&gt;` and silently drop the rule.

  Marking it raw is safe because nothing user-written reaches it. Every value
  the stylesheet interpolates is a closed enum or an integer, validated by
  `InvoiceDoc.Catalog` on the way in; the accent, which *is* user-set, never
  enters the CSS — it arrives as an inline custom property on the element.
  """
  def stylesheet(assigns) do
    assigns = assign(assigns, :tag, style_tag(assigns.doc, assigns.mode))

    ~H"""
    {@tag}
    """
  end

  defp style_tag(doc, mode) do
    Phoenix.HTML.raw([
      "<style>",
      QuantumBillingWeb.InvoiceDoc.Stylesheet.css(doc, mode: mode),
      "</style>"
    ])
  end

  attr :doc, Document, required: true
  attr :invoice, Invoice, required: true
  attr :accent, :string, default: "#18181b"
  attr :logo, :string, default: nil
  attr :class, :string, default: nil

  attr :only, :string,
    default: nil,
    doc: "render just this block, by id — the design pad's canvas cards"

  @doc """
  The invoice document.

  With `only`, renders a single block on its own; the pad shows each block in
  its own card, and it shows them by rendering the real thing rather than a
  stand-in, so what is dragged is what prints.
  """
  def document(assigns) do
    assigns = assign(assigns, :rows, rows(assigns.doc, assigns.only))

    ~H"""
    <div class={["qb-doc", @class]} style={"--qb-accent: #{@accent}"}>
      <%= for row <- @rows do %>
        <.row row={row} invoice={@invoice} logo={@logo} />
      <% end %>
    </div>
    """
  end

  attr :doc, Document, required: true
  attr :invoice, Invoice, required: true
  attr :accent, :string, default: "#18181b"
  attr :logo, :string, default: nil
  attr :scale, :float, default: 0.5

  @doc """
  The document at a fraction of its size, for previews and template thumbnails.

  Deliberately the same markup rather than a simplified stand-in: a preview that
  leaves detail out can agree with a setting the real document is not honouring,
  which is the failure the whole single-renderer arrangement exists to prevent.
  """
  def thumbnail(assigns) do
    ~H"""
    <div class="qb-doc-frame">
      <div class="qb-doc-scale" style={"transform: scale(#{@scale}); width: #{100 / @scale}%"}>
        <.document doc={@doc} invoice={@invoice} accent={@accent} logo={@logo} />
      </div>
    </div>
    """
  end

  attr :row, :list, required: true
  attr :invoice, Invoice, required: true
  attr :logo, :string, default: nil

  defp row(%{row: [block]} = assigns) do
    assigns = assign(assigns, :block, block)

    ~H"""
    <div class={["qb-doc__block", align_class(@block)]}>
      <.block block={@block} invoice={@invoice} logo={@logo} />
    </div>
    """
  end

  defp row(assigns) do
    ~H"""
    <div class="qb-doc__block qb-doc__row">
      <div :for={block <- @row} class={["qb-doc__cell", align_class(block)]}>
        <.block block={block} invoice={@invoice} logo={@logo} />
      </div>
    </div>
    """
  end

  attr :block, Block, required: true
  attr :invoice, Invoice, required: true
  attr :logo, :string, default: nil

  defp block(%{block: %Block{type: :logo}} = assigns) do
    ~H"""
    <img
      :if={@logo}
      src={@logo}
      alt=""
      class="qb-doc__logo"
      style={"max-height: #{@block.opts.max_height}px; max-width: #{@block.opts.max_width}px"}
    />
    <%!-- The fallback mark is an inline SVG rather than the application's
    `hero-*` classes, which are CSS masks from a stylesheet the print page does
    not load — through those the icon saved to PDF as a blank square. --%>
    <div :if={is_nil(@logo) and @block.opts.fallback == "mark"} class="qb-doc__brand">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.5"
        stroke="currentColor"
        aria-hidden="true"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="m9 14.25 6-6m4.5-3.493V21.75l-3.75-1.5-3.75 1.5-3.75-1.5-3.75 1.5V4.757c0-1.108.806-2.057 1.907-2.185a48.507 48.507 0 0 1 11.186 0c1.1.128 1.907 1.077 1.907 2.185ZM9.75 9h.008v.008H9.75V9Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm4.125 4.5h.008v.008h-.008V13.5Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Z"
        />
      </svg>
       <span class="qb-doc__brand-name">QuantumBilling</span>
    </div>
    """
  end

  defp block(%{block: %Block{type: :heading}} = assigns) do
    ~H"""
    <p class={[
      "qb-doc__heading",
      "qb-doc__heading--#{@block.opts.size}",
      @block.opts.color == "accent" && "qb-doc__heading--accent"
    ]}>
      {heading(@block, @invoice)}
    </p>
    """
  end

  defp block(%{block: %Block{type: :company}} = assigns) do
    ~H"""
    <p :if={@block.opts.label != ""} class="qb-doc__label">{@block.opts.label}</p>

    <p class="qb-doc__name">{@invoice.company_name || "—"}</p>

    <p :if={@block.opts.show_address and @invoice.company_address} class="qb-doc__muted">
      {@invoice.company_address}
    </p>

    <p :if={@block.opts.show_gstin and @invoice.company_gstin} class="qb-doc__muted">
      GSTIN: {@invoice.company_gstin}
    </p>

    <p :if={@block.opts.show_state and @invoice.company_state} class="qb-doc__muted">
      State: {@invoice.company_state}
    </p>
    """
  end

  defp block(%{block: %Block{type: :client}} = assigns) do
    ~H"""
    <p :if={@block.opts.label != ""} class="qb-doc__label">{@block.opts.label}</p>

    <p class="qb-doc__name">{@invoice.client_name}</p>

    <p :if={@block.opts.show_address and @invoice.client_billing_address} class="qb-doc__muted">
      {@invoice.client_billing_address}
    </p>

    <p :if={@block.opts.show_gstin and @invoice.client_gstin} class="qb-doc__muted">
      GSTIN: {@invoice.client_gstin}
    </p>

    <p :if={@block.opts.show_email and @invoice.client_email} class="qb-doc__muted">
      {@invoice.client_email}
    </p>

    <p :if={@block.opts.show_state and @invoice.client_state} class="qb-doc__muted">
      State: {@invoice.client_state}
    </p>
    """
  end

  defp block(%{block: %Block{type: :invoice_meta}} = assigns) do
    assigns = assign(assigns, :lines, visible_meta(assigns.block, assigns.invoice))

    ~H"""
    <dl>
      <div
        :for={line <- @lines}
        class={["qb-doc__meta-line", line.emphasis == "strong" && "qb-doc__meta-line--strong"]}
      >
        <dt :if={line.label != ""}>{line.label}</dt>
        
        <dd>{meta_value(line.field, @invoice)}</dd>
      </div>
    </dl>
    """
  end

  defp block(%{block: %Block{type: :divider}} = assigns) do
    ~H"""
    <hr class="qb-doc__divider" />
    """
  end

  defp block(%{block: %Block{type: :items}} = assigns) do
    assigns = assign(assigns, :columns, assigns.block.children)

    ~H"""
    <p :if={@block.opts.label != ""} class="qb-doc__label">{@block.opts.label}</p>

    <table class={[
      "qb-doc__items",
      @block.opts.zebra && "qb-doc__items--zebra",
      @block.opts.border == "none" && "qb-doc__items--plain"
    ]}>
      <thead>
        <tr>
          <th
            :for={column <- @columns}
            class={[align_class(column), column.width == "grow" && "qb-doc__items--grow"]}
          >
            {column.label}
          </th>
        </tr>
      </thead>
      
      <tbody>
        <tr :for={{item, index} <- Enum.with_index(@invoice.items, 1)}>
          <td :for={column <- @columns} class={align_class(column)}>
            {item_value(column, item, index)}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp block(%{block: %Block{type: :totals}} = assigns) do
    assigns = assign(assigns, :lines, visible_totals(assigns.block, assigns.invoice))

    ~H"""
    <div class="qb-doc__totals" style={"width: #{@block.opts.box_width}px; max-width: 100%"}>
      <div
        :for={line <- @lines}
        class={[
          "qb-doc__total-line",
          line.emphasis != "none" && "qb-doc__total-line--#{line.emphasis}"
        ]}
      >
        <span>{line.label}</span>
        <span>{Format.rupees(total_value(line.field, @invoice), decimals: 2, space: true)}</span>
      </div>
    </div>
    """
  end

  defp block(%{block: %Block{type: :amount_in_words}} = assigns) do
    ~H"""
    <p :if={@block.opts.label != ""} class="qb-doc__label">{@block.opts.label}</p>

    <p class="qb-doc__muted">{Format.rupees_in_words(@invoice.grand_total || 0)}</p>
    """
  end

  defp block(%{block: %Block{type: :remarks}} = assigns) do
    ~H"""
    <div :if={present?(@invoice.remarks)}>
      <p :if={@block.opts.label != ""} class="qb-doc__label">{@block.opts.label}</p>
      
      <p class="qb-doc__muted">{@invoice.remarks}</p>
    </div>
    """
  end

  defp block(%{block: %Block{type: :terms}} = assigns) do
    ~H"""
    <div :if={present?(@invoice.terms)}>
      <p :if={@block.opts.label != ""} class="qb-doc__label">{@block.opts.label}</p>
      
      <p class="qb-doc__muted">{@invoice.terms}</p>
    </div>
    """
  end

  defp block(%{block: %Block{type: :signature}} = assigns) do
    ~H"""
    <div class="qb-doc__signature">
      <div class="qb-doc__signature-space" style={"height: #{@block.opts.height}px"}></div>
      
      <p class="qb-doc__signature-caption qb-doc__muted">{@block.text}</p>
    </div>
    """
  end

  defp block(%{block: %Block{type: :footer}} = assigns) do
    ~H"""
    <p :if={present?(@block.text)} class="qb-doc__footer">{@block.text}</p>
    """
  end

  @doc """
  The title printed on the document.

  Falls back to the invoice's own type, so a Credit Note does not announce
  itself as a Tax Invoice just because nobody filled the heading in.
  """
  def heading(%Block{opts: %{text: text}}, %Invoice{} = invoice) do
    if present?(text), do: text, else: invoice.invoice_type
  end

  @doc """
  The blocks grouped into rows.

  Consecutive half-width blocks pair up; everything else takes a row of its own.
  A half with no partner is left on its own row rather than stretched, so
  removing one of a pair does not silently widen the other.
  """
  def rows(document, only \\ nil)

  def rows(%Document{} = document, nil) do
    Enum.chunk_while(document.blocks, [], &chunk/2, &last/1)
  end

  def rows(%Document{} = document, id) do
    case Document.block(document, id) do
      nil -> []
      block -> [[block]]
    end
  end

  defp chunk(block, []) do
    if half?(block), do: {:cont, [block]}, else: {:cont, [block], []}
  end

  defp chunk(block, [pending]) do
    if half?(block), do: {:cont, [pending, block], []}, else: {:cont, [pending], [block]}
  end

  defp last([]), do: {:cont, []}
  defp last(acc), do: {:cont, acc, []}

  defp half?(%Block{opts: opts}), do: Map.get(opts, :width) == "half"

  defp align_class(%Block{opts: opts}), do: align_class(opts)

  defp align_class(%{align: align}) when align in ["left", "center", "right"],
    do: "qb-doc--#{align}"

  defp align_class(_other), do: nil

  # -- field vocabularies ---------------------------------------------------
  #
  # Each of these is exhaustive over the field lists in `InvoiceDoc.Catalog`,
  # and the parser has already dropped anything outside them. The catch-all
  # clauses exist so a layout written by a future version renders a blank cell
  # rather than taking the invoice off the screen.

  defp item_value(%{field: "serial"}, _item, index), do: index
  defp item_value(%{field: "description"}, item, _index), do: item.description
  defp item_value(%{field: "hsn_sac"}, item, _index), do: item.hsn_sac || "—"
  defp item_value(%{field: "quantity"}, item, _index), do: item.quantity
  defp item_value(%{field: "unit"}, item, _index), do: item.unit
  defp item_value(%{field: "rate"}, item, _index), do: money(item.rate)
  defp item_value(%{field: "tax_rate"}, item, _index), do: "#{item.tax_rate}%"
  defp item_value(%{field: "amount"}, item, _index), do: money(item.amount)
  defp item_value(_column, _item, _index), do: nil

  defp total_value("taxable_value", invoice), do: invoice.taxable_value || 0
  defp total_value("cgst", invoice), do: invoice.cgst_amount || 0
  defp total_value("sgst", invoice), do: invoice.sgst_amount || 0
  defp total_value("igst", invoice), do: invoice.igst_amount || 0
  defp total_value("cess", invoice), do: invoice.cess_amount || 0
  defp total_value("round_off", invoice), do: invoice.round_off || 0
  defp total_value("grand_total", invoice), do: invoice.grand_total || 0
  defp total_value(_field, _invoice), do: 0

  defp meta_value("invoice_number", invoice), do: invoice.invoice_number
  defp meta_value("invoice_type", invoice), do: invoice.invoice_type
  defp meta_value("invoice_date", invoice), do: Format.format_date(invoice.invoice_date)
  defp meta_value("due_date", invoice), do: Format.format_date(invoice.due_date)
  defp meta_value("payment_terms", invoice), do: invoice.payment_terms
  defp meta_value("place_of_supply", invoice), do: invoice.place_of_supply
  defp meta_value("status", invoice), do: invoice.status
  defp meta_value(_field, _invoice), do: nil

  # Which tax applies is decided by the supply, not by the template.
  defp visible_totals(%Block{children: lines}, %Invoice{} = invoice) do
    intra_state? = Invoice.intra_state?(invoice)

    Enum.filter(lines, fn line ->
      applies?(line.field, intra_state?) and shown?(line, total_value(line.field, invoice))
    end)
  end

  defp applies?(field, true) when field in ["cgst", "sgst"], do: true
  defp applies?("igst", true), do: false
  defp applies?(field, false) when field in ["cgst", "sgst"], do: false
  defp applies?(_field, _intra_state?), do: true

  defp visible_meta(%Block{children: lines}, %Invoice{} = invoice) do
    Enum.filter(lines, fn line -> shown?(line, meta_value(line.field, invoice)) end)
  end

  defp shown?(%{when: "non-zero"}, value), do: value not in [nil, 0]
  defp shown?(%{when: "present"}, value), do: present?(value)
  defp shown?(_line, _value), do: true

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  # Line figures carry no space after the rupee sign and totals do. That is the
  # screen document's existing treatment; the print page disagreed on the line
  # figures, which is one of the divergences collapsing the two markups fixes.
  defp money(nil), do: Format.rupees(0, decimals: 2)
  defp money(amount), do: Format.rupees(amount, decimals: 2)
end
