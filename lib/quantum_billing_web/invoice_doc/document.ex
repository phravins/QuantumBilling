defmodule QuantumBillingWeb.InvoiceDoc.Document do
  @moduledoc """
  A parsed invoice layout: page setup and a flat, ordered block list.

  There are no containers. Two consecutive `width: "half"` blocks render side
  by side, which keeps reordering simple index arithmetic.
  """

  alias QuantumBillingWeb.InvoiceDoc.Block

  @type page :: %{
          size: String.t(),
          margin: String.t(),
          base_font: integer(),
          font: String.t(),
          line_height: String.t(),
          letter_spacing: String.t(),
          paragraph_spacing: String.t(),
          heading_font: String.t(),
          heading_weight: String.t(),
          heading_scale: String.t(),
          label_case: String.t(),
          table_density: String.t(),
          numerals: String.t(),
          text_color: String.t(),
          heading_color: String.t(),
          label_color: String.t(),
          muted_color: String.t(),
          border: String.t(),
          watermark: String.t(),
          watermark_text: String.t(),
          background: String.t(),
          background_fit: String.t(),
          background_opacity: String.t(),
          space_top: String.t(),
          space_bottom: String.t()
        }
  @type t :: %__MODULE__{version: integer(), page: page(), blocks: [Block.t()]}

  # Mirrors Layout.page_attrs/0 (reading it would be a cycle); LayoutTest checks they agree.
  defstruct version: 1,
            page: %{
              size: "A4",
              margin: "14mm",
              base_font: 12,
              font: "sans",
              line_height: "normal",
              letter_spacing: "normal",
              paragraph_spacing: "normal",
              heading_font: "match",
              heading_weight: "semibold",
              heading_scale: "normal",
              label_case: "upper",
              table_density: "normal",
              numerals: "proportional",
              text_color: "#18181b",
              heading_color: "text",
              label_color: "#71717a",
              muted_color: "#52525b",
              border: "none",
              watermark: "none",
              watermark_text: "",
              background: "",
              background_fit: "page",
              background_opacity: "100",
              space_top: "0mm",
              space_bottom: "0mm"
            },
            blocks: []

  @doc "The block with `id`, or `nil`."
  def block(%__MODULE__{blocks: blocks}, id), do: Enum.find(blocks, &(&1.id == id))

  @doc "Whether a block of `type` is already on the document."
  def has_type?(%__MODULE__{blocks: blocks}, type), do: Enum.any?(blocks, &(&1.type == type))

  @doc "Every block id, in render order."
  def ids(%__MODULE__{blocks: blocks}), do: Enum.map(blocks, & &1.id)

  @doc """
  Replaces the block with the same id. A no-op for an unknown id, so stale clicks can't restore it.
  """
  def put_block(%__MODULE__{} = doc, %Block{} = block) do
    %{doc | blocks: Enum.map(doc.blocks, fn b -> if b.id == block.id, do: block, else: b end)}
  end

  @doc "A sequential unused block id, so layouts stay legible and round trips stable."
  def next_id(%__MODULE__{} = doc) do
    taken = MapSet.new(ids(doc))
    Enum.find_value(1..1_000, fn n -> if !MapSet.member?(taken, "b#{n}"), do: "b#{n}" end)
  end
end
