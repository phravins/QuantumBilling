defmodule QuantumBillingWeb.EWayBillsLive do
  @moduledoc """
  Placeholder page for the E-Way Bills section, pending its own data model.
  """
  use QuantumBillingWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "E-Way Bills", active_nav: :e_way_bills)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <.header>
        {@page_title}
        <:subtitle>Coming soon</:subtitle>
      </.header>
      <.coming_soon />
    </Layouts.app>
    """
  end
end
