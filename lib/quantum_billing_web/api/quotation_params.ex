defmodule QuantumBillingWeb.API.QuotationParams do
  @moduledoc """
  The fields an API caller may set when creating a quotation: the invoice
  allowlist (`InvoiceParams`) with the quotation's dates in place of the
  invoice's. Anything else, `status` and `number` included, is refused by
  name. Client details come from the client record.

  `quotation_date` defaults to today and `valid_until` to the business's
  validity period after it.
  """

  alias QuantumBillingWeb.API.InvoiceParams

  @top ~w(client_id quotation_date valid_until place_of_supply remarks terms items custom_fields)

  @doc """
  `{:ok, client_id, attrs}` for `Quotations.create_quotation/2`, or
  `{:error, fields}`. Amounts are minor units of `currency`, the business's.
  """
  def cast(body, regime, currency),
    do:
      InvoiceParams.cast_document(body, regime, %{
        top: @top,
        object: "quotation",
        item_object: "quotation_item",
        currency: currency
      })
end
