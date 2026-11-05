defmodule QuantumBillingWeb.API.V1.FallbackController do
  @moduledoc """
  A JSON 404 for unmatched `/api/v1` paths. Reached only after auth, so
  unauthenticated callers get 401 everywhere.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBillingWeb.API.Error

  def not_found(conn, _params), do: Error.send(conn, 404, :not_found, "No such endpoint.")
end
