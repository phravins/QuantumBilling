defmodule QuantumBillingWeb.InvoiceDoc.Document do
  @moduledoc """
  A parsed invoice layout: the page setup, and the ordered blocks on it.

  ## The block list is flat

  There are no rows or containers. A two-column head — the logo on the left and
  the invoice meta on the right — is expressed by giving both blocks
  `width: "half"`, and the renderer packs consecutive halves into a pair.

  One rule, one list. Reordering is then index arithmetic, which is what keeps
  the design pad's drag, its up/down buttons and the serialiser simple. Nested
  containers would complicate all three for the sake of one affordance.
  """

  alias QuantumBillingWeb.InvoiceDoc.Block

  @type page :: %{size: String.t(), margin: String.t(), base_font: integer(), font: String.t()}
  @type t :: %__MODULE__{version: integer(), page: page(), blocks: [Block.t()]}

  defstruct version: 1,
            page: %{size: "A4", margin: "14mm", base_font: 12, font: "sans"},
            blocks: []

  @doc "The block with `id`, or `nil`."
  def block(%__MODULE__{blocks: blocks}, id), do: Enum.find(blocks, &(&1.id == id))

  @doc "Whether a block of `type` is already on the document."
  def has_type?(%__MODULE__{blocks: blocks}, type), do: Enum.any?(blocks, &(&1.type == type))

  @doc "Every block id, in render order."
  def ids(%__MODULE__{blocks: blocks}), do: Enum.map(blocks, & &1.id)

  @doc """
  Replaces the block with the same id.

  A no-op when the id is not on the document, so a stale click from a pad that
  has since removed the block cannot resurrect it.
  """
  def put_block(%__MODULE__{} = doc, %Block{} = block) do
    %{doc | blocks: Enum.map(doc.blocks, fn b -> if b.id == block.id, do: block, else: b end)}
  end

  @doc """
  An id no block on the document is using.

  Sequential rather than random so a hand-read layout stays legible, and so a
  round trip through the serialiser is stable.
  """
  def next_id(%__MODULE__{} = doc) do
    taken = MapSet.new(ids(doc))
    Enum.find_value(1..1_000, fn n -> if !MapSet.member?(taken, "b#{n}"), do: "b#{n}" end)
  end
end
