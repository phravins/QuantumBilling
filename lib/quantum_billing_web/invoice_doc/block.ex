defmodule QuantumBillingWeb.InvoiceDoc.Block do
  @moduledoc """
  One block of an invoice layout — a logo, the item table, the totals box.

  ## Why one struct rather than one per block type

  The block types have genuinely different options, so a struct each would be
  the obvious modelling. The safety that buys — no block carrying a key that
  makes no sense for it — is instead provided by `InvoiceDoc.Catalog`, which
  holds a per-type whitelist that both the parser and the design pad cast
  through. Nothing else may write `opts`.

  One struct means the parser, the serialiser and the pad's reorder logic are
  each written once against a uniform shape, rather than thirteen times. The
  renderer still dispatches on `type`, so it reads the same either way.

  `children` carries the ordered sub-elements the three composite blocks have:
  `<column>` for `:items`, `<line>` for `:totals` and `:invoice_meta`. Every
  other block has none. `text` carries element content — the footer's copy and
  the signature's caption — which lives in the element body rather than an
  attribute so that newlines survive without escaping.
  """

  @type t :: %__MODULE__{
          type: atom(),
          id: String.t(),
          opts: map(),
          children: [map()],
          text: String.t() | nil
        }

  defstruct [:type, :id, :text, opts: %{}, children: []]
end
