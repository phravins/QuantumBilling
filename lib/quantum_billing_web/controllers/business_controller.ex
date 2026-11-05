defmodule QuantumBillingWeb.BusinessController do
  @moduledoc """
  Switches the browser's business. A controller because the choice is in the
  session; other tabs follow (`UserAuth.broadcast_business_switch/2`), and this
  one goes on to `BusinessReadyLive`.
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
      |> redirect(to: ~p"/businesses/ready")
    else
      _not_a_member -> PageController.not_found(conn, %{})
    end
  end
end
