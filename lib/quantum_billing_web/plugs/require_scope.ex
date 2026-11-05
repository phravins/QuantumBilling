defmodule QuantumBillingWeb.Plugs.RequireScope do
  @moduledoc """
  Refuses an API call whose key lacks the scope (403, checked before any lookup).
  Used per action in the API controllers.
  """

  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBillingWeb.API.Error

  def init(scope) when is_binary(scope), do: scope

  def call(%{assigns: %{api_key: key}} = conn, scope) do
    if ApiKey.has_scope?(key, scope) do
      conn
    else
      Error.send(conn, 403, :insufficient_scope, "This API key does not have the #{scope} scope.")
    end
  end
end
