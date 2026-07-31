defmodule QuantumBillingWeb.PageController do
  use QuantumBillingWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  @doc """
  Renders the branded 404 for any path the router does not recognise.

  Reached from the catch-all route, which exists so unknown URLs never raise
  `Phoenix.Router.NoRouteError` — in development that exception surfaces the
  debug page and its full listing of every route in the application.

  Layouts are switched off because the template is a complete HTML document.
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
