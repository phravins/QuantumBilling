defmodule QuantumBillingWeb.Plugs.RequireScope do
  @moduledoc """
  Refuses an API call the key was not granted the scope for.

  Used per action in each API controller. A missing scope is 403, not 404:
  the caller is authenticated and is being told plainly what their key lacks,
  which is what an integrator needs to fix it. Nothing about the resource is
  disclosed by that — the check happens before anything is looked up.
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
