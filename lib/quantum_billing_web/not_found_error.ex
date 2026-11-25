defmodule QuantumBillingWeb.NotFoundError do
  @moduledoc """
  Raised to answer 404, so a page the caller may not see looks like one that
  does not exist. Phoenix renders `ErrorHTML`'s 404 page for it.
  """
  defexception message: "not found", plug_status: 404
end
