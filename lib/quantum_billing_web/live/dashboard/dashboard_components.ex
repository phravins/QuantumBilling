defmodule QuantumBillingWeb.DashboardComponents do
  @moduledoc """
  UI building blocks for the QuantumBilling dashboard: stat cards, an inline
  CSS bar chart, an inline SVG donut chart, status pills, and the compliance
  calendar date badge.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]
  import QuantumBillingWeb.SharedComponents, only: [card: 1]

  @doc """
  Renders a single dashboard stat card with an icon badge, label, value,
  and an optional trend line underneath the value (`delta_text`, styled by
  `delta_class` and optionally preceded by a `delta_icon` heroicon).
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true
  attr :icon_class, :string, default: "bg-base-200 text-base-content/60"
  attr :delta_text, :string, default: nil
  attr :delta_class, :string, default: "text-success"
  attr :delta_icon, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <.card>
      <div class={["mb-3 flex size-8 items-center justify-center rounded-field", @icon_class]}>
        <.icon name={@icon} class="size-4" />
      </div>
      <p class="text-sm text-base-content/60">{@label}</p>
      <p class="mt-1 text-2xl font-semibold tracking-tight">{@value}</p>
      <p :if={@delta_text} class={["mt-1.5 flex items-center gap-1 text-xs", @delta_class]}>
        <.icon :if={@delta_icon} name={@delta_icon} class="size-3" />
        {@delta_text}
      </p>
    </.card>
    """
  end

  @doc """
  Renders a grouped vertical bar chart from a list of
  `%{label:, cgst_sgst:, igst:}` maps, scaled against `max`.
  """
  attr :months, :list, required: true
  attr :max, :integer, default: 2000

  def bar_chart(assigns) do
    months =
      Enum.map(assigns.months, fn m ->
        Map.merge(m, %{
          cgst_pct: m.cgst_sgst / assigns.max * 100,
          igst_pct: m.igst / assigns.max * 100
        })
      end)

    gridlines = Enum.map(4..0//-1, &(&1 * div(assigns.max, 4)))

    assigns = assign(assigns, months: months, gridlines: gridlines)

    ~H"""
    <div class="flex gap-3">
      <div class="flex h-64 flex-col justify-between text-xs text-base-content/45">
        <span :for={g <- @gridlines}>{g}</span>
      </div>
      <div class="relative flex-1">
        <div class="absolute inset-0 flex flex-col justify-between">
          <div :for={_g <- @gridlines} class="h-0 border-t border-base-200" />
        </div>
        <div class="relative flex h-64 items-end justify-between gap-6 px-2">
          <div :for={m <- @months} class="flex h-full flex-1 items-end justify-center gap-1.5">
            <div class="w-3 rounded-sm bg-base-content" style={"height: #{m.cgst_pct}%"} />
            <div class="w-3 rounded-sm bg-base-content/25" style={"height: #{m.igst_pct}%"} />
          </div>
        </div>
        <div class="mt-2 flex justify-between gap-6 px-2">
          <span :for={m <- @months} class="flex-1 text-center text-xs text-base-content/60">
            {m.label}
          </span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders an SVG donut chart with a centered total and an adjacent legend,
  from a list of `%{label:, value:, tone:}` maps.

  `tone` is one of `:strong`, `:medium`, `:soft` or `:faint` — the ring is a
  monochrome ramp, so the segments read as one series rather than four
  unrelated colors.
  """
  attr :segments, :list, required: true
  attr :total, :integer, required: true
  attr :total_label, :string, default: "Total"

  def donut_chart(assigns) do
    assigns = assign(assigns, :segments, donut_geometry(assigns.segments))

    ~H"""
    <div class="flex items-center gap-6">
      <div class="relative size-40 shrink-0">
        <svg viewBox="0 0 42 42" class="size-40 -rotate-90">
          <circle
            :for={seg <- @segments}
            cx="21"
            cy="21"
            r="15.9155"
            fill="none"
            stroke-width="5"
            class={stroke_class(seg.tone)}
            stroke-dasharray={seg.dasharray}
            stroke-dashoffset={seg.dashoffset}
          />
        </svg>
        <div class="absolute inset-0 flex flex-col items-center justify-center">
          <span class="text-2xl font-semibold tracking-tight">{format_number(@total)}</span>
          <span class="text-xs text-base-content/60">{@total_label}</span>
        </div>
      </div>
      <ul class="flex-1 space-y-3">
        <li :for={seg <- @segments} class="flex items-center justify-between gap-4 text-sm">
          <span class="flex items-center gap-2 text-base-content/60">
            <span class={["size-2.5 rounded-full", dot_class(seg.tone)]} />
            {seg.label}
          </span>
          <span class="font-medium">{format_number(seg.value)}</span>
        </li>
      </ul>
    </div>
    """
  end

  # Written out in full rather than interpolated: Tailwind scans source text, so
  # a class built as "stroke-#{tone}" is never emitted and the ring renders blank.
  defp stroke_class(:strong), do: "stroke-base-content"
  defp stroke_class(:medium), do: "stroke-base-content/60"
  defp stroke_class(:soft), do: "stroke-base-content/35"
  defp stroke_class(:faint), do: "stroke-base-content/15"

  defp dot_class(:strong), do: "bg-base-content"
  defp dot_class(:medium), do: "bg-base-content/60"
  defp dot_class(:soft), do: "bg-base-content/35"
  defp dot_class(:faint), do: "bg-base-content/15"

  defp donut_geometry(segments) do
    total = Enum.reduce(segments, 0, fn seg, acc -> acc + seg.value end)

    {rows, _acc} =
      Enum.map_reduce(segments, 0, fn seg, acc ->
        pct = seg.value / total * 100
        row = Map.merge(seg, %{dasharray: "#{pct} #{100 - pct}", dashoffset: -acc})
        {row, acc + pct}
      end)

    rows
  end

  @doc """
  Renders the small bordered month/day badge used in the compliance calendar.
  """
  attr :month, :string, required: true
  attr :day, :string, required: true

  def compliance_date_badge(assigns) do
    ~H"""
    <div class="flex size-10 shrink-0 flex-col items-center justify-center rounded-field border border-base-300 bg-base-200 text-base-content">
      <span class="text-2xs font-medium uppercase text-base-content/45">{@month}</span>
      <span class="text-sm font-semibold leading-tight">{@day}</span>
    </div>
    """
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
