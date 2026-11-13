defmodule QuantumBillingWeb.InvoiceDoc.Renderer do
  @moduledoc """
  Renders an invoice from its layout: the only invoice markup.

  The page, print view, thumbnails and design pad all render here. Styling
  comes from `InvoiceDoc.Stylesheet`, not Tailwind. Whatever the layout says,
  CGST/SGST print only intra-state and IGST only inter-state, `non-zero` lines
  hide at zero, and an empty heading falls back to the invoice type.

  A VAT invoice prints its VAT number in place of the GSTIN, a VAT line per
  rate in place of the GST lines, a VAT summary when it mixes rates, and the
  reverse-charge legend. HSN / SAC prints only if a line has a code.
  """
  use Phoenix.Component

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Tax
  alias QuantumBillingWeb.CustomFieldComponents
  alias QuantumBillingWeb.Format
  alias QuantumBillingWeb.InvoiceDoc.Block
  alias QuantumBillingWeb.InvoiceDoc.Document

  attr :doc, Document, required: true
  attr :mode, :atom, default: :screen, values: [:screen, :print]

  @doc """
  The document's stylesheet in a `<style>` tag.

  Built as a safe value because HEEx does not interpolate inside `<style>`.
  Every interpolated value is a validated enum or integer; the user-set accent
  arrives as an inline custom property instead.
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

  attr :extras, :map,
    default: %{payment: nil, images: %{}, custom: %{invoice: [], items: []}},
    doc: "payment details and image sources, from `InvoiceDoc.Extras.build/3`"

  @doc "The invoice document. With `only`, renders just that block (for the design pad)."
  def document(assigns) do
    page = assigns.doc.page
    sheet? = is_nil(assigns.only)
    extras = assigns.extras || %{}
    images = Map.get(extras, :images) || %{}

    background =
      if sheet?, do: Map.get(images, Map.get(page, :background, "")), else: nil

    watermark = if sheet?, do: watermark(page, assigns.invoice), else: nil

    assigns =
      assigns
      |> assign(:rows, rows(assigns.doc, assigns.only))
      |> assign(:sheet?, sheet?)
      |> assign(:background, background)
      |> assign(:watermark, watermark)
      |> assign(:layered?, not is_nil(background) or not is_nil(watermark))
      |> assign(:payment, Map.get(extras, :payment))
      |> assign(:images, images)
      |> assign(:custom, Map.get(extras, :custom) || %{invoice: [], items: []})
      |> assign(:page, page)

    ~H"""
    <div
      class={[
        "qb-doc",
        @sheet? && "qb-doc--sheet",
        @layered? && "qb-doc--layered",
        @background && "qb-doc--letterhead",
        @class
      ]}
      style={"--qb-accent: #{@accent}"}
    >
      <%= for row <- @rows do %>
        <.row
          row={row}
          invoice={@invoice}
          logo={@logo}
          payment={@payment}
          images={@images}
          custom={@custom}
          editing={not @sheet?}
        />
      <% end %>
      <%!-- After the blocks, so `.qb-doc__block:first-child` still finds the first block. --%>
      <img
        :if={@background}
        src={@background}
        alt=""
        class={[
          "qb-doc__background",
          "qb-doc__background--#{@page.background_fit}",
          "qb-doc__background--o#{@page.background_opacity}"
        ]}
      />
      <div :if={@watermark} class="qb-doc__watermark" aria-hidden="true">
        <span>{@watermark}</span>
      </div>
    </div>
    """
  end

  # A status watermark marks only the states a reader should not miss.
  @watermarked_statuses ~w(draft paid cancelled)

  defp watermark(%{watermark: "status"}, %Invoice{status: status}) when is_binary(status) do
    if String.downcase(status) in @watermarked_statuses, do: String.upcase(status)
  end

  defp watermark(%{watermark: "custom", watermark_text: text}, _invoice) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 40)
    end
  end

  defp watermark(_page, _invoice), do: nil

  attr :doc, Document, required: true
  attr :invoice, Invoice, required: true
  attr :accent, :string, default: "#18181b"
  attr :logo, :string, default: nil
  attr :scale, :float, default: 0.5
  attr :extras, :map, default: %{payment: nil, images: %{}}

  @doc "The same document scaled down, for previews and thumbnails."
  def thumbnail(assigns) do
    ~H"""
    <div class="qb-doc-frame">
      <div class="qb-doc-scale" style={"transform: scale(#{@scale}); width: #{100 / @scale}%"}>
        <.document doc={@doc} invoice={@invoice} accent={@accent} logo={@logo} extras={@extras} />
      </div>
    </div>
    """
  end

  attr :row, :list, required: true
  attr :invoice, Invoice, required: true
  attr :logo, :string, default: nil
  attr :payment, :map, default: nil
  attr :images, :map, default: %{}
  attr :custom, :map, default: %{invoice: [], items: []}
  attr :editing, :boolean, default: false

  defp row(%{row: [block]} = assigns) do
    assigns = assign(assigns, :block, block)

    ~H"""
    <div class={["qb-doc__block", align_class(@block)]}>
      <.block
        block={@block}
        invoice={@invoice}
        logo={@logo}
        payment={@payment}
        images={@images}
        custom={@custom}
        editing={@editing}
      />
    </div>
    """
  end

  defp row(assigns) do
    ~H"""
    <div class="qb-doc__block qb-doc__row">
      <div :for={block <- @row} class={["qb-doc__cell", align_class(block)]}>
        <.block
          block={block}
          invoice={@invoice}
          logo={@logo}
          payment={@payment}
          images={@images}
          custom={@custom}
          editing={@editing}
        />
      </div>
    </div>
    """
  end

  attr :block, Block, required: true
  attr :invoice, Invoice, required: true
  attr :logo, :string, default: nil
  attr :payment, :map, default: nil
  attr :images, :map, default: %{}
  attr :custom, :map, default: %{invoice: [], items: []}
  attr :editing, :boolean, default: false

  defp block(%{block: %Block{type: :logo}} = assigns) do
    ~H"""
    <img
      :if={@logo}
      src={@logo}
      alt=""
      class="qb-doc__logo"
      style={"max-height: #{@block.opts.max_height}px; max-width: #{@block.opts.max_width}px"}
    />
    <%!-- Inline SVG: the print page does not load the hero-* mask classes. --%>
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

    <p :if={@block.opts.show_gstin and tax_number(@invoice, :company)} class="qb-doc__muted">
      {tax_number_label(@invoice)}: {tax_number(@invoice, :company)}
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

    <p :if={@block.opts.show_gstin and tax_number(@invoice, :client)} class="qb-doc__muted">
      {tax_number_label(@invoice)}: {tax_number(@invoice, :client)}
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
    assigns =
      assign(
        assigns,
        :columns,
        assigns.block.children
        |> Enum.map(&serial_label/1)
        |> regime_columns(assigns.invoice)
        |> with_custom_columns(assigns.custom.items, assigns.invoice.items)
      )
      |> assign(:vat_summary, vat_summary(assigns.invoice))

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
            class={[align_class(column), Map.get(column, :width) == "grow" && "qb-doc__items--grow"]}
          >
            {column_label(column.label, @invoice.currency)}
          </th>
        </tr>
      </thead>

      <tbody>
        <tr :for={{item, index} <- Enum.with_index(@invoice.items, 1)}>
          <td :for={column <- @columns} class={align_class(column)}>
            {item_value(column, item, index, @invoice)}
          </td>
        </tr>
      </tbody>
    </table>

    <table :if={@vat_summary != []} class="qb-doc__items qb-doc__vat-summary">
      <thead>
        <tr>
          <th>VAT summary</th>
          <th class="qb-doc--right">Taxable amount</th>
          <th class="qb-doc--right">VAT</th>
        </tr>
      </thead>

      <tbody>
        <tr :for={row <- @vat_summary}>
          <td>{Tax.breakdown_label(row)}</td>
          <td class="qb-doc--right">{money(row["taxable"], @invoice.currency)}</td>
          <td class="qb-doc--right">{money(row["tax"], @invoice.currency)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp block(%{block: %Block{type: :custom_fields}} = assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        custom_rows(assigns.custom.invoice, assigns.invoice, assigns.editing)
      )

    ~H"""
    <div :if={@rows != []}>
      <p :if={@block.opts.label != ""} class="qb-doc__label">{@block.opts.label}</p>

      <dl>
        <div :for={{label, text} <- @rows} class="qb-doc__meta-line">
          <dt>{label}</dt>
          <dd>{text}</dd>
        </div>
      </dl>
    </div>

    <p :if={@rows == [] and @editing} class="qb-doc__muted">
      Invoice fields marked "Show on invoice" print here.
    </p>
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
        <span>
          {Format.money(line.value, @invoice.currency, decimals: 2, space: true)}
        </span>
      </div>

      <p :if={Tax.reverse_charge_legend(@invoice)} class="qb-doc__muted qb-doc__legend">
        {Tax.reverse_charge_legend(@invoice)}
      </p>
    </div>
    """
  end

  defp block(%{block: %Block{type: :amount_in_words}} = assigns) do
    ~H"""
    <p :if={@block.opts.label != ""} class="qb-doc__label">{@block.opts.label}</p>

    <p class="qb-doc__muted">
      {Format.amount_in_words(@invoice.grand_total || 0, @invoice.currency)}
    </p>
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

  defp block(%{block: %Block{type: :custom_text}} = assigns) do
    ~H"""
    <div
      :if={present?(@block.opts.title) or present?(@block.text)}
      class={["qb-doc__note", "qb-doc__note--#{@block.opts.style}"]}
    >
      <p :if={present?(@block.opts.title)} class="qb-doc__note-title">{@block.opts.title}</p>
      <p :if={present?(@block.text)} class="qb-doc__muted">{@block.text}</p>
    </div>
    """
  end

  defp block(%{block: %Block{type: :spacer}} = assigns) do
    assigns = assign(assigns, :height, clamp(assigns.block.opts.height, 0, 400))

    ~H"""
    <div class={["qb-doc__spacer", @editing && "qb-doc__spacer--edit"]} style={"height: #{@height}px"}>
    </div>
    """
  end

  defp block(%{block: %Block{type: :payment}} = assigns) do
    payment = assigns.payment || %{upi_id: nil, payee: nil, qr: "", bank: []}
    opts = assigns.block.opts

    assigns =
      assigns
      |> assign(:upi_id, if(opts.show_upi, do: payment.upi_id))
      |> assign(:payee, if(opts.show_upi, do: payment.payee))
      |> assign(:qr, if(opts.show_qr and payment.qr not in [nil, ""], do: payment.qr))
      |> assign(:bank, if(opts.show_bank, do: payment.bank, else: []))
      |> assign(:qr_size, clamp(opts.qr_size, 48, 200))

    assigns =
      assign(
        assigns,
        :empty?,
        is_nil(assigns.upi_id) and is_nil(assigns.qr) and assigns.bank == []
      )

    ~H"""
    <div :if={not @empty? or @editing}>
      <p :if={@block.opts.label != ""} class="qb-doc__label">{@block.opts.label}</p>

      <div class="qb-doc__payment">
        <%!-- The SVG is generated on the server from the UPI URI; nothing user-written is in it. --%>
        <div :if={@qr} class="qb-doc__qr" style={"width: #{@qr_size}px; height: #{@qr_size}px"}>
          {Phoenix.HTML.raw(@qr)}
        </div>

        <div class="qb-doc__payment-lines">
          <p :if={@upi_id} class="qb-doc__payment-line">
            <span class="qb-doc__payment-key">UPI</span> <span>{@upi_id}</span>
          </p>
          <p :if={@upi_id && @payee} class="qb-doc__payment-line">
            <span class="qb-doc__payment-key">Payee</span> <span>{@payee}</span>
          </p>
          <p :for={{label, value} <- @bank} class="qb-doc__payment-line">
            <span class="qb-doc__payment-key">{label}</span> <span>{value}</span>
          </p>
          <p :if={@empty?} class="qb-doc__muted">
            Add a UPI ID or bank details in Settings to fill this in.
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp block(%{block: %Block{type: :image}} = assigns) do
    assigns =
      assigns
      |> assign(:src, Map.get(assigns.images || %{}, assigns.block.opts.path))
      |> assign(:max_height, clamp(assigns.block.opts.max_height, 16, 400))

    ~H"""
    <img
      :if={@src}
      src={@src}
      alt=""
      class="qb-doc__image"
      style={"max-height: #{@max_height}px"}
    />
    <div :if={is_nil(@src) and @editing} class="qb-doc__placeholder">
      Upload an image, stamp or seal
    </div>
    """
  end

  @doc "The title printed on the document; falls back to the invoice's own type."
  def heading(%Block{opts: %{text: text}}, %Invoice{} = invoice) do
    if present?(text), do: text, else: invoice.invoice_type
  end

  @doc """
  The blocks grouped into rows. Consecutive half-width blocks pair up; an
  unpaired half keeps its own row.
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

  # Catch-alls render blank for fields from a newer version.

  defp item_value(%{field: "serial"}, _item, index, _invoice), do: index
  defp item_value(%{field: "description"}, item, _index, _invoice), do: item.description
  defp item_value(%{field: "hsn_sac"}, item, _index, _invoice), do: item.hsn_sac || "—"

  defp item_value(%{field: "quantity"}, item, _index, _invoice),
    do: Format.quantity(item.quantity)

  defp item_value(%{field: "unit"}, item, _index, _invoice), do: item.unit
  defp item_value(%{field: "rate"}, item, _index, invoice), do: money(item.rate, invoice.currency)

  defp item_value(%{field: "tax_rate"}, item, _index, invoice) do
    if Invoice.vat?(invoice), do: vat_rate_label(item), else: "#{item.tax_rate}%"
  end

  defp item_value(%{field: "amount"}, item, _index, invoice),
    do: money(item.amount, invoice.currency)

  defp item_value(%{custom: definition}, item, _index, invoice),
    do: custom_text(definition, item.custom_fields, invoice.currency) || "—"

  defp item_value(_column, _item, _index, _invoice), do: nil

  # A zero-rated line prints 0%; exempt and out-of-scope lines print the word.
  defp vat_rate_label(%{tax_category: category, tax_rate_bp: rate_bp}) do
    if Tax.untaxed_category?(category) and category != "zero",
      do: Tax.category_label(category),
      else: Tax.percent_label(rate_bp)
  end

  # Templates saved before the default became "S.No" still say "#".
  defp serial_label(%{field: "serial", label: "#"} = column), do: %{column | label: "S.No"}
  defp serial_label(column), do: column

  # VAT drops the HSN column unless a line has a code, and names the defaults for VAT.
  defp regime_columns(columns, %Invoice{tax_regime: "vat", items: items}) do
    coded? = is_list(items) and Enum.any?(items, &present?(&1.hsn_sac))

    for column <- columns, column.field != "hsn_sac" or coded? do
      case column do
        %{field: "hsn_sac", label: "HSN / SAC"} -> %{column | label: "Item Code"}
        %{field: "tax_rate", label: "Tax (%)"} -> %{column | label: "VAT"}
        column -> column
      end
    end
  end

  defp regime_columns(columns, _invoice), do: columns

  # The per-rate table prints only when an invoice mixes rates.
  defp vat_summary(%Invoice{tax_regime: "vat", tax_breakdown: [_, _ | _] = rows}), do: rows
  defp vat_summary(_invoice), do: []

  defp tax_number(%Invoice{tax_regime: "vat"} = invoice, :company),
    do: presence(invoice.company_tax_number)

  defp tax_number(%Invoice{tax_regime: "vat"} = invoice, :client),
    do: presence(invoice.client_tax_number)

  defp tax_number(invoice, :company), do: invoice.company_gstin
  defp tax_number(invoice, :client), do: invoice.client_gstin

  defp tax_number_label(%Invoice{tax_regime: "vat"}), do: "VAT No. / TRN"
  defp tax_number_label(_invoice), do: "GSTIN"

  # Headings default to "Rate (₹)"; another currency shows its own symbol.
  defp column_label(label, currency) when is_binary(label) and currency not in [nil, "INR"],
    do: String.replace(label, "₹", Format.currency_symbol(currency))

  defp column_label(label, _currency), do: label

  # Item fields with a value on some line become columns, placed before Amount.
  defp with_custom_columns(columns, [], _items), do: columns

  defp with_custom_columns(columns, definitions, items) do
    items = if is_list(items), do: items, else: []

    extra =
      for definition <- definitions,
          Enum.any?(items, &(custom_text(definition, &1.custom_fields, nil) != nil)) do
        %{
          field: "custom:" <> definition.key,
          custom: definition,
          label: definition.label,
          align: if(definition.type in ~w(money number), do: "right", else: "left"),
          width: "auto"
        }
      end

    case Enum.split_while(columns, &(&1.field != "amount")) do
      {before, [_amount | _rest] = from_amount} -> before ++ extra ++ from_amount
      {all, []} -> all ++ extra
    end
  end

  # The pad's sample has no values, so it shows each active field with a dash.
  defp custom_rows(definitions, invoice, editing?) do
    for definition <- definitions,
        text =
          custom_text(definition, invoice.custom_fields, invoice.currency) ||
            (editing? && is_nil(definition.archived_at) && "—"),
        text,
        do: {definition.label, text}
  end

  defp custom_text(definition, values, currency) do
    value = Map.get(values || %{}, definition.key)

    case CustomFieldComponents.display_value(definition, value, currency) do
      text when text in [nil, ""] -> nil
      text -> text
    end
  end

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

  @gst_lines ~w(cgst sgst igst cess)

  defp visible_totals(%Block{children: lines}, %Invoice{tax_regime: "vat"} = invoice) do
    vat_lines = vat_lines(invoice)

    # The VAT lines take the place of the first GST line, else go before the total.
    {before, rest} = Enum.split_while(lines, &(&1.field not in @gst_lines))

    {before, rest} =
      if rest == [],
        do: Enum.split_while(lines, &(&1.field != "grand_total")),
        else: {before, rest}

    kept = fn part ->
      for line <- part,
          line.field not in @gst_lines,
          value = total_value(line.field, invoice),
          shown?(line, value),
          line.field != "round_off" or value != 0,
          do: Map.put(line, :value, value)
    end

    kept.(before) ++ vat_lines ++ kept.(rest)
  end

  defp visible_totals(%Block{children: lines}, %Invoice{} = invoice) do
    intra_state? = Invoice.intra_state?(invoice)

    for line <- lines,
        value = total_value(line.field, invoice),
        applies?(line.field, intra_state?) and shown?(line, value),
        do: Map.put(line, :value, value)
  end

  # One line per taxed rate: "VAT 5%", or the rate's name when two share a percentage.
  # Nothing taxed (all exempt, or reverse charge) still prints the VAT as one line.
  defp vat_lines(%Invoice{} = invoice) do
    taxed =
      Enum.filter(invoice.tax_breakdown || [], fn row ->
        not Tax.untaxed_category?(row["category"]) and (row["rate_bp"] || 0) > 0
      end)

    percents = Enum.frequencies_by(taxed, & &1["rate_bp"])

    case {invoice.reverse_charge, taxed} do
      {true, _taxed} ->
        [%{label: "VAT (reverse charge)", emphasis: "none", value: 0}]

      {_reverse?, []} ->
        [%{label: "VAT", emphasis: "none", value: invoice.vat_amount || 0}]

      {_reverse?, taxed} ->
        for row <- taxed do
          label =
            if percents[row["rate_bp"]] == 1,
              do: Tax.percent_label(row["rate_bp"]),
              else: Tax.breakdown_label(row)

          %{label: "VAT " <> label, emphasis: "none", value: row["tax"] || 0}
        end
    end
  end

  defp applies?(field, true) when field in ["cgst", "sgst"], do: true
  defp applies?("igst", true), do: false
  defp applies?(field, false) when field in ["cgst", "sgst"], do: false
  defp applies?(_field, _intra_state?), do: true

  defp visible_meta(%Block{children: lines}, %Invoice{} = invoice) do
    Enum.filter(lines, fn line ->
      value = meta_value(line.field, invoice)

      shown?(line, value) and
        (line.field != "place_of_supply" or present?(value) or not Invoice.vat?(invoice))
    end)
  end

  defp shown?(%{when: "non-zero"}, value), do: value not in [nil, 0]
  defp shown?(%{when: "present"}, value), do: present?(value)
  defp shown?(_line, _value), do: true

  defp clamp(value, low, high) when is_integer(value), do: value |> max(low) |> min(high)
  defp clamp(_value, low, _high), do: low

  defp presence(value), do: if(present?(value), do: value)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  # No space after the rupee sign on line figures; totals have one.
  defp money(nil, currency), do: Format.money(0, currency, decimals: 2)
  defp money(amount, currency), do: Format.money(amount, currency, decimals: 2)
end
