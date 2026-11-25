defmodule QuantumBillingWeb.InvoiceDoc.QuotationLayout do
  @moduledoc """
  Turns an invoice design into a quotation's: a pure function over the parsed
  `Document`, so a quotation prints with the business's own design.

    * the title reads "Quotation" (a heading is added when the design has none)
    * the dates read "Quotation Date" and "Valid Until"
    * payment terms and status lines are dropped
    * the payment block (UPI QR, bank) is dropped: a quotation is not payable
    * the custom-fields block stays, and prints the quotation's own fields
  """

  alias QuantumBillingWeb.InvoiceDoc.Block
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document

  @dropped_blocks [:payment]
  @dropped_meta ~w(payment_terms status)

  @doc "The quotation version of `document`."
  def adapt(%Document{} = document) do
    blocks =
      document.blocks
      |> Enum.reject(&(&1.type in @dropped_blocks))
      |> Enum.map(&adapt_block/1)
      |> ensure_heading()

    # A status watermark would read DRAFT on every quotation.
    page =
      if document.page.watermark == "status",
        do: %{document.page | watermark: "none"},
        else: document.page

    %{document | blocks: blocks, page: page}
  end

  # Blank text falls back to the document's type, "Quotation".
  defp adapt_block(%Block{type: :heading} = block),
    do: %{block | opts: Map.put(block.opts, :text, "")}

  defp adapt_block(%Block{type: :invoice_meta, children: lines} = block) do
    lines =
      lines
      |> Enum.reject(&(&1.field in @dropped_meta))
      |> Enum.map(&relabel/1)

    %{block | children: lines}
  end

  defp adapt_block(block), do: block

  defp relabel(%{field: "invoice_date"} = line), do: Map.put(line, :label, "Quotation Date")

  defp relabel(%{field: "due_date"} = line),
    do: Map.merge(line, %{label: "Valid Until", when: "always"})

  defp relabel(line), do: line

  defp ensure_heading(blocks) do
    if Enum.any?(blocks, &(&1.type == :heading)),
      do: blocks,
      else: [Catalog.new(:heading, "quotation-heading") | blocks]
  end
end
