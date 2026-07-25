defmodule QuantumBillingWeb.PlaceholderLive do
  @moduledoc """
  Shared "coming soon" page for the sidebar sections that don't have a
  built-out module yet (Invoices, Clients, E-Way Bills, Reports,
  Compliance, Settings), keyed off `@live_action`.
  """
  use QuantumBillingWeb, :live_view

  @meta %{
    invoices: %{title: "Invoices", nav: :invoices},
    clients: %{title: "Clients", nav: :clients},
    e_way_bills: %{title: "E-Way Bills", nav: :e_way_bills},
    reports: %{title: "Reports", nav: :reports},
    compliance: %{title: "Compliance", nav: :compliance},
    settings: %{title: "Settings", nav: :settings}
  }

  def mount(_params, _session, socket) do
    %{title: title, nav: nav} = Map.fetch!(@meta, socket.assigns.live_action)

    {:ok, assign(socket, page_title: title, active_nav: nav)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <.header>
        {@page_title}
        <:subtitle>Coming soon</:subtitle>
      </.header>

      <div class="card rounded-box border border-base-300 bg-base-100 p-16 text-center text-base-content/50">
        This section is under construction.
      </div>
    </Layouts.app>
    """
  end
end
