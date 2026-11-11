defmodule QuantumBillingWeb.PageController do
  use QuantumBillingWeb, :controller

  @doc """
  The branded 404 for the catch-all route, so unknown paths never raise
  `NoRouteError`. The template is a full document, so layouts are off.
  """
  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(html: QuantumBillingWeb.ErrorHTML)
    |> put_root_layout(html: false)
    |> put_layout(html: false)
    |> render(:"404")
  end
end
