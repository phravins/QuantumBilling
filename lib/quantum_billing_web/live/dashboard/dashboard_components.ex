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

  attr :tone, :atom,
    default: :neutral,
    values: [:neutral, :info, :success, :warning, :danger, :accent],
    doc: "colours the icon badge; `:neutral` is the original grey"

  attr :icon_class, :string,
    default: nil,
    doc: "overrides `tone` outright, for a badge that needs its own classes"

  attr :delta_text, :string, default: nil
  attr :delta_class, :string, default: "text-success"
  attr :delta_icon, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <.card>
      <div class={[
        "mb-2.5 flex size-7 items-center justify-center rounded-field",
        @icon_class || tone_class(@tone)
      ]}>
        <.icon name={@icon} class="size-3.5" />
      </div>

      <p class="text-xs text-base-content/60">{@label}</p>

      <p class="mt-0.5 text-2xl font-semibold tracking-tight">{@value}</p>

      <p :if={@delta_text} class={["mt-1 flex items-center gap-1 text-xs", @delta_class]}>
        <.icon :if={@delta_icon} name={@delta_icon} class="size-3" /> {@delta_text}
      </p>
    </.card>
    """
  end

  # Literal class strings so Tailwind emits them.
  defp tone_class(:info), do: "bg-blue-500/10 text-blue-600 dark:text-blue-400"
  defp tone_class(:success), do: "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
  defp tone_class(:warning), do: "bg-amber-500/10 text-amber-600 dark:text-amber-400"
  defp tone_class(:danger), do: "bg-rose-500/10 text-rose-600 dark:text-rose-400"
  defp tone_class(:accent), do: "bg-violet-500/10 text-violet-600 dark:text-violet-400"
  defp tone_class(:neutral), do: "bg-base-200 text-base-content/60"

  @doc """
  Renders a smooth multi-series area chart.

  `series` is a list of `%{label:, tone:, values:}`, all sharing the `labels`
  x-axis. `tone` is `:blue`, `:violet` or `:emerald`.

  ## How it is drawn

  The plot lives in a 0-100 user-space viewBox stretched with
  `preserveAspectRatio="none"`, so it fills whatever box it is given. Strokes
  carry `vector-effect="non-scaling-stroke"` so the stretch does not thicken
  them, and the point markers are HTML rather than SVG circles — a circle in a
  non-uniformly scaled viewBox renders as an ellipse.

  Points run edge to edge: the first sits on the left frame and the last on the
  right, so the fill reaches both sides of the card. Inset points left a bare
  strip down either side of the plot and gave the area a hard vertical edge
  that read as a chart that had failed to finish drawing.

  The draw-in is a clip that sweeps across, not a dashed stroke. A dash pattern
  cannot be used on these paths: `vector-effect: non-scaling-stroke` makes the
  browser measure dashes in screen pixels, and it then ignores `pathLength`,
  so whatever length the dash was given, the far end of a wide chart stayed
  inside the gap and the line stopped before its last reading.
  """
  attr :id, :string, required: true, doc: "namespaces the gradient defs"
  attr :series, :list, required: true
  attr :labels, :list, required: true
  attr :max, :any, required: true
  attr :axis_labels, :list, required: true, doc: "five y-axis labels, top down"

  attr :format, :any,
    default: nil,
    doc: "formats a value for the hover tooltip; defaults to plain digits"

  attr :class, :any, default: nil

  def area_chart(assigns) do
    count = length(assigns.labels)
    max = if is_number(assigns.max) and assigns.max > 0, do: assigns.max, else: 1
    format = assigns.format || (&plain_number/1)

    plotted =
      Enum.map(assigns.series, fn s ->
        points =
          s.values
          |> Enum.with_index()
          |> Enum.map(fn {value, i} ->
            %{
              x: x_at(i, count),
              y: 100 - value / max * 100,
              value: value,
              display: format.(value)
            }
          end)

        coords = Enum.map(points, &{&1.x, &1.y})

        Map.merge(s, %{
          points: points,
          line: curve(coords),
          area: area(coords)
        })
      end)

    columns =
      assigns.labels
      |> Enum.with_index()
      |> Enum.map(fn {label, i} ->
        %{
          label: label,
          x: x_at(i, count),
          anchor: anchor(i, count),
          readings:
            Enum.map(plotted, fn s ->
              %{label: s.label, tone: s.tone, display: Enum.at(s.points, i).display}
            end)
        }
      end)

    dots =
      Enum.flat_map(plotted, fn s ->
        Enum.map(s.points, &Map.put(&1, :tone, s.tone))
      end)

    assigns = assign(assigns, plotted: plotted, columns: columns, dots: dots)

    ~H"""
    <div class={["flex min-h-56 gap-3", @class]}>
      <div class="flex shrink-0 flex-col text-xs text-base-content/45">
        <div class="flex min-h-0 flex-1 flex-col justify-between">
          <span :for={label <- @axis_labels}>{label}</span>
        </div>
        <%!-- Matches the x-label row so the y labels align with their gridlines. --%>
        <div class="mt-2 h-4" aria-hidden="true"></div>
      </div>

      <div class="flex min-w-0 flex-1 flex-col">
        <div class="group/chart relative min-h-0 flex-1">
          <div class="absolute inset-0 flex flex-col justify-between">
            <div :for={_label <- @axis_labels} class="h-0 border-t border-base-200" />
          </div>

          <svg
            viewBox="0 0 100 100"
            preserveAspectRatio="none"
            class="absolute inset-0 size-full overflow-visible"
            aria-hidden="true"
          >
            <defs>
              <linearGradient :for={s <- @plotted} id={"#{@id}-#{s.tone}"} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" class={gradient_top_class(s.tone)} />
                <stop offset="100%" class={gradient_bottom_class(s.tone)} />
              </linearGradient>

              <%!-- Oversized so scaling cannot clip the stroke. --%>
              <clipPath id={"#{@id}-sweep"} clipPathUnits="userSpaceOnUse">
                <rect class="qb-chart-sweep" x="-4" y="-20" width="108" height="140" />
              </clipPath>
            </defs>

            <path
              :for={s <- @plotted}
              class="qb-chart-area"
              d={s.area}
              fill={"url(##{@id}-#{s.tone})"}
            />
            <g clip-path={"url(##{@id}-sweep)"}>
              <path
                :for={s <- @plotted}
                class={["qb-chart-line", line_class(s.tone)]}
                d={s.line}
                fill="none"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
                vector-effect="non-scaling-stroke"
              />
            </g>
          </svg>

          <span
            :for={dot <- @dots}
            class={[
              "qb-chart-dot absolute size-2.5 -translate-x-1/2 -translate-y-1/2 rounded-full",
              "border-2 border-base-100 shadow-sm",
              dot_fill_class(dot.tone)
            ]}
            style={"left: #{fmt(dot.x)}%; top: #{fmt(dot.y)}%"}
          />

          <%!-- Full-height hover target per month. --%>
          <div class="absolute inset-0 flex">
            <div :for={column <- @columns} class="group/col relative flex-1">
              <div
                class={[
                  "absolute inset-y-0 w-px -translate-x-1/2 bg-base-content/20",
                  "opacity-0 transition-opacity group-hover/col:opacity-100"
                ]}
                style={"left: #{fmt(column.x)}%"}
              />

              <div
                class={[
                  "pointer-events-none absolute top-1 z-10 w-max",
                  "rounded-field border border-base-300 bg-base-100 px-2.5 py-1.5 shadow-lg",
                  "opacity-0 transition-opacity group-hover/col:opacity-100",
                  anchor_class(column.anchor)
                ]}
                style={"left: #{fmt(column.x)}%"}
              >
                <p class="text-2xs font-medium uppercase tracking-wide text-base-content/45">
                  {column.label}
                </p>

                <p
                  :for={reading <- column.readings}
                  class="mt-0.5 flex items-center gap-1.5 whitespace-nowrap text-xs"
                >
                  <span class={["size-1.5 shrink-0 rounded-full", dot_fill_class(reading.tone)]} />
                  <span class="text-base-content/60">{reading.label}</span>
                  <span class="ml-auto font-medium">{reading.display}</span>
                </p>
              </div>
            </div>
          </div>
        </div>

        <%!-- Absolutely positioned so labels sit under their points; the end labels hang inward. --%>
        <div class="relative mt-2 h-4">
          <span
            :for={column <- @columns}
            class={["absolute text-xs text-base-content/60", anchor_class(column.anchor)]}
            style={"left: #{fmt(column.x)}%"}
          >
            {column.label}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # A single reading sits in the middle.
  defp x_at(i, count) when count > 1, do: i / (count - 1) * 100
  defp x_at(_i, _count), do: 50.0

  # Monotone cubic (Fritsch-Carlson) as beziers. Unlike Catmull-Rom it never
  # overshoots, so the curve never shows revenue that was not invoiced.
  defp curve([]), do: ""
  defp curve([{x, y}]), do: "M #{fmt(x)} #{fmt(y)}"

  defp curve([{x0, y0} | _] = points) do
    body =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.zip(Enum.chunk_every(tangents(points), 2, 1, :discard))
      |> Enum.map_join(" ", fn {[{x1, y1}, {x2, y2}], [m1, m2]} ->
        run = (x2 - x1) / 3

        "C #{fmt(x1 + run)} #{fmt(y1 + m1 * run)}, " <>
          "#{fmt(x2 - run)} #{fmt(y2 - m2 * run)}, #{fmt(x2)} #{fmt(y2)}"
      end)

    "M #{fmt(x0)} #{fmt(y0)} " <> body
  end

  defp tangents(points) do
    secants =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{x1, y1}, {x2, y2}] -> (y2 - y1) / (x2 - x1) end)

    interior =
      secants
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [before, aftr] -> interior_slope(before, aftr) end)

    limit([hd(secants)] ++ interior ++ [List.last(secants)], secants)
  end

  defp interior_slope(before, aftr) when before * aftr <= 0, do: 0.0
  defp interior_slope(before, aftr), do: (before + aftr) / 2

  # Fritsch-Carlson: scale tangents back onto the radius-3 circle to stay monotone.
  defp limit(raw, secants) do
    raw
    |> Enum.with_index()
    |> Map.new(fn {slope, i} -> {i, slope} end)
    |> then(fn slopes ->
      secants
      |> Enum.with_index()
      |> Enum.reduce(slopes, &limit_segment/2)
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp limit_segment({secant, index}, slopes) when secant == 0.0 do
    slopes |> Map.put(index, 0.0) |> Map.put(index + 1, 0.0)
  end

  defp limit_segment({secant, index}, slopes) do
    start = Map.fetch!(slopes, index) / secant
    finish = Map.fetch!(slopes, index + 1) / secant
    radius = start * start + finish * finish

    if radius > 9 do
      scale = 3 / :math.sqrt(radius)

      slopes
      |> Map.put(index, scale * start * secant)
      |> Map.put(index + 1, scale * finish * secant)
    else
      slopes
    end
  end

  defp area([]), do: ""

  defp area(points) do
    {first_x, _} = hd(points)
    {last_x, _} = List.last(points)

    "#{curve(points)} L #{fmt(last_x)} 100 L #{fmt(first_x)} 100 Z"
  end

  defp fmt(number), do: :erlang.float_to_binary(number * 1.0, decimals: 2)

  defp plain_number(value) when is_float(value), do: plain_number(round(value))
  defp plain_number(value), do: format_number(value)

  @doc """
  Formats a rupee amount for a chart axis or tooltip, in Indian units.

  Public because the Reports chart labels its axis the same way, and two
  copies of this would drift into labelling the same number differently on
  two pages.
  """
  def money_axis_label(value) when value >= 10_000_000,
    do: "₹" <> short(value / 10_000_000) <> "Cr"

  def money_axis_label(value) when value >= 100_000, do: "₹" <> short(value / 100_000) <> "L"
  def money_axis_label(value) when value >= 1_000, do: "₹" <> short(value / 1_000) <> "K"
  def money_axis_label(value), do: "₹#{round(value)}"

  defp short(number) do
    number
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
  end

  defp gradient_top_class(:blue), do: "[stop-color:var(--color-blue-500)] [stop-opacity:0.28]"
  defp gradient_top_class(:violet), do: "[stop-color:var(--color-violet-400)] [stop-opacity:0.28]"

  defp gradient_top_class(:emerald),
    do: "[stop-color:var(--color-emerald-500)] [stop-opacity:0.28]"

  defp gradient_bottom_class(:blue), do: "[stop-color:var(--color-blue-500)] [stop-opacity:0]"
  defp gradient_bottom_class(:violet), do: "[stop-color:var(--color-violet-400)] [stop-opacity:0]"

  defp gradient_bottom_class(:emerald),
    do: "[stop-color:var(--color-emerald-500)] [stop-opacity:0]"

  defp anchor(0, count) when count > 1, do: :start
  defp anchor(i, count) when i == count - 1 and count > 1, do: :end
  defp anchor(_i, _count), do: :middle

  defp anchor_class(:start), do: "translate-x-0"
  defp anchor_class(:end), do: "-translate-x-full"
  defp anchor_class(:middle), do: "-translate-x-1/2"

  defp line_class(:blue), do: "stroke-blue-500"
  defp line_class(:violet), do: "stroke-violet-400"
  defp line_class(:emerald), do: "stroke-emerald-500"

  defp dot_fill_class(:blue), do: "bg-blue-500"
  defp dot_fill_class(:violet), do: "bg-violet-400"
  defp dot_fill_class(:emerald), do: "bg-emerald-500"

  @doc """
  Renders an SVG donut chart with a centered total and an adjacent legend,
  from a list of `%{label:, value:, tone:}` maps.

  `tone` is one of `:strong`, `:medium`, `:positive`, `:soft` or `:faint`.

  `palette` picks how those tones are rendered:

    * `:mono` (default) — a monochrome ramp, so the segments read as one series
      rather than four unrelated colors. This is what the dashboard uses.
    * `:color` — a categorical palette, for the Reports page, where charts are
      the one place colour is allowed.

  The default keeps every existing caller monochrome.
  """
  attr :segments, :list, required: true
  attr :total, :integer, required: true
  attr :total_label, :string, default: "Total"
  attr :palette, :atom, default: :mono, values: [:mono, :color]
  attr :show_percent, :boolean, default: false

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
            class={stroke_class(@palette, seg.tone)}
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
            <span class={["size-2.5 shrink-0 rounded-full", dot_class(@palette, seg.tone)]} /> {seg.label}
          </span>

          <span class="whitespace-nowrap font-medium">
            {format_number(seg.value)}
            <span :if={@show_percent} class="font-normal text-base-content/45">
              ({seg.percent}%)
            </span>
          </span>
        </li>
      </ul>
    </div>
    """
  end

  # Literal class strings so Tailwind emits them.
  defp stroke_class(:mono, :strong), do: "stroke-base-content"
  defp stroke_class(:mono, :medium), do: "stroke-base-content/60"
  defp stroke_class(:mono, :positive), do: "stroke-base-content/45"
  defp stroke_class(:mono, :soft), do: "stroke-base-content/35"
  defp stroke_class(:mono, :faint), do: "stroke-base-content/15"
  defp stroke_class(:color, :strong), do: "stroke-blue-500"
  defp stroke_class(:color, :medium), do: "stroke-amber-500"
  defp stroke_class(:color, :positive), do: "stroke-emerald-500"
  defp stroke_class(:color, :soft), do: "stroke-rose-500"
  defp stroke_class(:color, :faint), do: "stroke-base-content/20"

  defp dot_class(:mono, :strong), do: "bg-base-content"
  defp dot_class(:mono, :medium), do: "bg-base-content/60"
  defp dot_class(:mono, :positive), do: "bg-base-content/45"
  defp dot_class(:mono, :soft), do: "bg-base-content/35"
  defp dot_class(:mono, :faint), do: "bg-base-content/15"
  defp dot_class(:color, :strong), do: "bg-blue-500"
  defp dot_class(:color, :medium), do: "bg-amber-500"
  defp dot_class(:color, :positive), do: "bg-emerald-500"
  defp dot_class(:color, :soft), do: "bg-rose-500"
  defp dot_class(:color, :faint), do: "bg-base-content/20"

  defp donut_geometry(segments) do
    total = Enum.reduce(segments, 0, fn seg, acc -> acc + seg.value end)

    {rows, _acc} =
      Enum.map_reduce(segments, 0, fn seg, acc ->
        pct = seg.value / total * 100

        row =
          Map.merge(seg, %{
            dasharray: "#{pct} #{100 - pct}",
            dashoffset: -acc,
            percent: :erlang.float_to_binary(pct, decimals: 1)
          })

        {row, acc + pct}
      end)

    rows
  end

  @doc """
  Renders the small bordered month/day badge used in the compliance calendar.
  """
  attr :month, :string, required: true
  attr :day, :string, required: true

  attr :tone, :atom,
    default: :neutral,
    values: [:neutral, :due_soon, :overdue],
    doc: "tints the badge so a missed deadline is visible before the text is read"

  def compliance_date_badge(assigns) do
    ~H"""
    <div class={[
      "flex size-10 shrink-0 flex-col items-center justify-center rounded-field border",
      badge_tone_class(@tone)
    ]}>
      <span class="text-2xs font-medium uppercase opacity-60">{@month}</span>
      <span class="text-sm font-semibold leading-tight">{@day}</span>
    </div>
    """
  end

  defp badge_tone_class(:overdue),
    do:
      "border-rose-200 bg-rose-50 text-rose-700 dark:border-rose-900 dark:bg-rose-950 dark:text-rose-300"

  defp badge_tone_class(:due_soon),
    do:
      "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300"

  defp badge_tone_class(:neutral), do: "border-base-300 bg-base-200 text-base-content"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
