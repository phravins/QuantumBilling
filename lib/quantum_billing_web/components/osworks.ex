defmodule QuantumBillingWeb.OSWorks do
  @moduledoc """
  The OSWORKS credit: QuantumBilling is an open-source project of the OSWORKS
  open source community.
  """
  use Phoenix.Component

  @doc """
  Renders the OSWORKS mark: four corner brackets in the text colour and three
  orange bars, with a light sheen sweeping across it (still with reduced motion).
  """
  attr :id, :string, default: "osworks-mark", doc: "prefix for the SVG's internal ids"
  attr :class, :string, default: nil

  def mark(assigns) do
    ~H"""
    <svg
      id={@id}
      class={["qb-osworks-mark", @class]}
      viewBox="0 0 96 96"
      fill="none"
      aria-hidden="true"
      focusable="false"
    >
      <defs>
        <clipPath id={"#{@id}-clip"}>
          <.shapes />
        </clipPath>
        <linearGradient id={"#{@id}-sheen"} x1="0" x2="1" y1="0" y2="0">
          <stop offset="0" stop-color="#fff" stop-opacity="0" />
          <stop offset="0.5" stop-color="#fff" stop-opacity="0.85" />
          <stop offset="1" stop-color="#fff" stop-opacity="0" />
        </linearGradient>
      </defs>
      <g fill="currentColor">
        <.brackets />
      </g>
      <g class="qb-osworks-bars" fill="#EB5A12">
        <.bars />
      </g>
      <g clip-path={"url(##{@id}-clip)"}>
        <g transform="skewX(-20)">
          <rect
            class="qb-osworks-sheen"
            x="-40"
            y="0"
            width="28"
            height="96"
            fill={"url(##{@id}-sheen)"}
          />
        </g>
      </g>
    </svg>
    """
  end

  defp shapes(assigns) do
    ~H"""
    <.brackets />
    <.bars />
    """
  end

  defp brackets(assigns) do
    ~H"""
    <path d="M8 45V18L18 8H45V20H24L20 24V45Z" />
    <path d="M51 8H78L88 18V45H76V24L72 20H51Z" />
    <path d="M8 51H20V72L24 76H45V88H18L8 78Z" />
    <path d="M76 51H88V78L78 88H51V76H72L76 72Z" />
    """
  end

  defp bars(assigns) do
    ~H"""
    <rect x="33" y="32" width="30" height="7" />
    <rect x="33" y="44.5" width="30" height="7" />
    <rect x="33" y="57" width="30" height="7" />
    """
  end
end
