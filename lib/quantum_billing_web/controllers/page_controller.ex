defmodule QuantumBillingWeb.PageController do
  use QuantumBillingWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
