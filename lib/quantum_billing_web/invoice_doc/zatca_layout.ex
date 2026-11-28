defmodule QuantumBillingWeb.InvoiceDoc.ZatcaLayout do
  @moduledoc """
  Makes an invoice design meet ZATCA Phase 1 for a Saudi invoice: a pure
  function over the parsed `Document`, applied at render time only, so the
  business's saved design is never changed.

  For an invoice `QuantumBilling.Zatca.applies?/1` accepts:

    * the heading reads the ZATCA title in English and Arabic ("Simplified
      Tax Invoice" / "فاتورة ضريبية مبسطة" and so on), whatever the design's
      own text; a heading is added when the design has none
    * the "Type" line is dropped, since the title already says it
    * the seller block shows the address and VAT number; a standard (B2B)
      invoice shows the buyer's too. Missing seller, buyer or details blocks
      are added below the heading, along with the invoice number and date
    * the QR code block goes after the totals, or at the end
    * the document is marked `bilingual`, so default labels print in Arabic
      too and the stylesheet loads the Arabic font

  Any other invoice comes back unchanged.
  """

  alias QuantumBilling.Zatca
  alias QuantumBillingWeb.InvoiceDoc.Block
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Renderer

  @qr_id "zatca-qr"
  @required_meta ~w(invoice_number invoice_date)

  @doc "The ZATCA version of `document` for `invoice`, or `document` itself."
  def adapt(%Document{} = document, invoice) do
    if Zatca.applies?(invoice) do
      title = Zatca.title(invoice)
      standard? = not Zatca.simplified?(invoice)

      blocks =
        document.blocks
        |> Enum.map(&adapt_block(&1, title, standard?))
        |> ensure_heading(title)
        |> ensure_required(standard?)

      blocks = ensure_qr(%{document | blocks: blocks})

      %{document | blocks: blocks, bilingual: true}
    else
      document
    end
  end

  defp adapt_block(%Block{type: :heading} = block, title, _standard?), do: titled(block, title)

  defp adapt_block(%Block{type: :company} = block, _title, _standard?),
    do: put_opts(block, show_address: true, show_gstin: true)

  defp adapt_block(%Block{type: :client} = block, _title, true),
    do: put_opts(block, show_address: true, show_gstin: true)

  defp adapt_block(%Block{type: :invoice_meta, children: lines} = block, _title, _standard?) do
    lines = Enum.reject(lines, &(&1.field == "invoice_type"))
    fields = Enum.map(lines, & &1.field)

    missing =
      for field <- @required_meta,
          field not in fields,
          line = Catalog.new_child(:invoice_meta, field),
          do: line

    %{block | children: missing ++ lines}
  end

  defp adapt_block(block, _title, _standard?), do: block

  defp titled(%Block{} = block, {english, arabic}),
    do: %{block | opts: Map.merge(block.opts, %{text: english, text_ar: arabic})}

  defp ensure_heading(blocks, title) do
    if Enum.any?(blocks, &(&1.type == :heading)),
      do: blocks,
      else: [titled(Catalog.new(:heading, "zatca-heading"), title) | blocks]
  end

  # Added full width, so they never pair up with a half-width block the
  # design already places.
  defp ensure_required(blocks, standard?) do
    types = if standard?, do: [:company, :invoice_meta, :client], else: [:company, :invoice_meta]

    missing =
      for type <- types,
          not Enum.any?(blocks, &(&1.type == type)),
          block = Catalog.new(type, "zatca-" <> String.replace(to_string(type), "_", "-")),
          do: block |> put_opts(width: "full") |> adapt_block(nil, standard?)

    insert_after_row(blocks, :heading, missing)
  end

  defp ensure_qr(%Document{blocks: blocks} = document) do
    if Document.has_type?(document, :zatca_qr) do
      blocks
    else
      qr = %Block{type: :zatca_qr, id: @qr_id, opts: %{width: "full", align: "right"}}
      insert_after_row(blocks, :totals, [qr])
    end
  end

  # After the row holding a block of `type`, so a half-width pair stays
  # together; at the end when there is none.
  defp insert_after_row(blocks, _type, []), do: blocks

  defp insert_after_row(blocks, type, new_blocks) do
    rows = Renderer.rows(%Document{blocks: blocks})
    {before, rest} = Enum.split_while(rows, fn row -> not Enum.any?(row, &(&1.type == type)) end)

    case rest do
      [] -> blocks ++ new_blocks
      [row | rest] -> Enum.concat(before) ++ row ++ new_blocks ++ Enum.concat(rest)
    end
  end

  defp put_opts(%Block{} = block, opts), do: %{block | opts: Map.merge(block.opts, Map.new(opts))}
end
