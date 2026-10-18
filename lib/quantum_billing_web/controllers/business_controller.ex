defmodule QuantumBillingWeb.BusinessController do
  @moduledoc """
  Switches the business a browser works in.

  A controller rather than a LiveView event because the choice lives in the
  session cookie, and only an HTTP response can write that. Every tab of the
  browser follows: see `QuantumBillingWeb.UserAuth.broadcast_business_switch/2`.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBillingWeb.PageController
  alias QuantumBillingWeb.UserAuth

  def switch(conn, %{"id" => id}) do
    # Only the businesses the scope already lists: the user's own, not archived.
    # Anything else is a 404, so a forged id says nothing about what exists.
    with {id, ""} <- Integer.parse(id),
         %{} = business <- Enum.find(conn.assigns.current_scope.businesses, &(&1.id == id)) do
      conn
      |> put_session(:business_id, business.id)
      |> UserAuth.broadcast_business_switch(business.id)
      |> put_flash(:info, "Now working in #{business.name}.")
      |> redirect(to: ~p"/")
    else
      _not_a_member -> PageController.not_found(conn, %{})
    end
  end
end
