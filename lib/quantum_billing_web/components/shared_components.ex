defmodule QuantumBillingWeb.SharedComponents do
  @moduledoc """
  Small UI building blocks shared across more than one feature folder
  (e.g. the GST invoice status pill is used by both Dashboard and Invoices).
  """
  use Phoenix.Component

  @doc """
  Renders a colored status pill for the given GST invoice status string.
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-soft", status_badge_class(@status)]}>{@status}</span>
    """
  end

  defp status_badge_class("E-Invoice Generated"), do: "badge-success"
  defp status_badge_class("Pending E-Invoice"), do: "badge-warning"
  defp status_badge_class("Draft"), do: "badge-neutral"
  defp status_badge_class("E-Invoice Failed"), do: "badge-error"
  defp status_badge_class("Cancelled"), do: "badge-neutral"

  @doc """
  Renders the shared "coming soon" empty-state card used by placeholder pages.
  """
  attr :title, :string, default: "This section is under construction."

  def coming_soon(assigns) do
    ~H"""
    <div class="card rounded-box border border-base-300 bg-base-100 p-16 text-center text-base-content/50">
      {@title}
    </div>
    """
  end
end
