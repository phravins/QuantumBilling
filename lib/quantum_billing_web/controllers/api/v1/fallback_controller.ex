defmodule QuantumBillingWeb.API.V1.FallbackController do
  @moduledoc """
  Any `/api/v1` path that matches no route.

  A JSON 404 in the API's error shape, rather than the branded HTML page the
  catch-all at the bottom of the router serves. Reached only after
  authentication, so an unauthenticated caller cannot use it to map which
  paths exist: they get the 401 for every path alike.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBillingWeb.API.Error

  def not_found(conn, _params), do: Error.send(conn, 404, :not_found, "No such endpoint.")
end
