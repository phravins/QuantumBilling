defmodule QuantumBillingWeb.InvoiceDoc.Block do
  @moduledoc """
  One block of an invoice layout (logo, item table, totals, ...).

  One struct for every type; `InvoiceDoc.Catalog` whitelists each type's
  `opts`. `children` holds `<column>` (`:items`) or `<line>` (`:totals`,
  `:invoice_meta`) elements. `text` holds element content (footer,
  signature caption).
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
