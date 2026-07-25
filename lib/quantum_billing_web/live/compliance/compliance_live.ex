defmodule QuantumBillingWeb.ComplianceLive do
  @moduledoc """
  Placeholder page for the Compliance section, pending its own data model.
  """
  use QuantumBillingWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Compliance", active_nav: :compliance)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        {@page_title}
        <:subtitle>Coming soon</:subtitle>
      </.header>
      <.coming_soon />
    </Layouts.app>
    """
  end
end
