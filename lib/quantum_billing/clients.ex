defmodule QuantumBilling.Clients do
  @moduledoc """
  Customers a tenant invoices.

  A placeholder pending the multi-tenant Ecto schema: `list_clients/0` returns
  nothing because no clients table exists yet. It is here so the LiveViews stop
  owning their own records — when the schema lands this becomes a `Repo` query
  and no caller has to change.
  """

  @doc """
  Every client on the account.

  Returns `[]` until the clients table exists.
  """
  def list_clients, do: []
end
