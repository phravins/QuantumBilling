defmodule QuantumBillingWeb.GSTOnly do
  @moduledoc """
  Keeps a VAT business off the India GST pages, sending it to the dashboard
  with the reason. As a LiveView hook, `on_mount {GSTOnly, :e_way_bills}`; as a
  controller plug, `plug GSTOnly, :e_way_bills`. The feature names the message
  (see `QuantumBilling.Tax.gst_only_message/1`).
  """
  use QuantumBillingWeb, :verified_routes

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Tax

  def on_mount(feature, _params, _session, socket) do
    if Scope.vat?(socket.assigns[:current_scope]) do
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, Tax.gst_only_message(feature))
       |> Phoenix.LiveView.redirect(to: ~p"/dashboard")}
    else
      {:cont, socket}
    end
  end

  def init(feature), do: feature

  def call(conn, feature) do
    if Scope.vat?(conn.assigns[:current_scope]) do
      conn
      |> Phoenix.Controller.put_flash(:error, Tax.gst_only_message(feature))
      |> Phoenix.Controller.redirect(to: ~p"/dashboard")
      |> Plug.Conn.halt()
    else
      conn
    end
  end
end
