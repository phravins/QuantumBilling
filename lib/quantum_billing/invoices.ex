defmodule QuantumBilling.Invoices do
  @moduledoc """
  GST invoices.

  A placeholder pending the multi-tenant Ecto schema: `list_invoices/0` returns
  nothing because no invoice table exists yet. It is here so the LiveViews stop
  owning their own records — when the schema lands this becomes a `Repo` query
  and no caller has to change.
  """

  @doc """
  Every invoice, newest first.

  Returns `[]` until the invoices table exists.
  """
  def list_invoices, do: []
end
