defmodule QuantumBillingWeb.ReportsComponents do
  @moduledoc """
  Building blocks for the Reports page: the invoice-value trend chart and the
  labelled controls in the filters panel.

  The chart is hand-rolled inline SVG, the same dependency-free approach as
  `QuantumBillingWeb.DashboardComponents.bar_chart/1`. Reports is the one place
  in the app where charts carry colour; everything around them stays in the
  monochrome language the rest of the UI uses.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]
  import QuantumBillingWeb.SharedComponents, only: [form_select_class: 0, form_input_class: 0]

  @doc """
  Renders an area + line chart from a list of `%{label:, value:}` maps.

  The plot is drawn in a 0-100 user-space viewBox stretched with
  `preserveAspectRatio="none"`, so it fills whatever box it is given. The stroke
  uses `vector-effect="non-scaling-stroke"` so that stretching does not thicken
  it, and the point markers are HTML rather than SVG circles — a circle in a
  non-uniformly scaled viewBox would render as an ellipse.
  """
  attr :points, :list, required: true
  attr :class, :any, default: nil

  def line_chart(assigns) do
    values = Enum.map(assigns.points, & &1.value)
    max = values |> Enum.max(fn -> 0 end) |> nice_max()
    count = length(assigns.points)

    plotted =
      assigns.points
      |> Enum.with_index()
      |> Enum.map(fn {point, i} ->
        Map.merge(point, %{x: x_position(i, count), y: 100 - point.value / max * 100})
      end)

    line = Enum.map_join(plotted, " ", fn p -> "#{fmt(p.x)},#{fmt(p.y)}" end)

    assigns =
      assign(assigns,
        plotted: plotted,
        line_points: line,
        area_points: line <> " 100,100 0,100",
        gridlines: Enum.map(4..0//-1, &axis_label(div(max, 4) * &1)),
        empty?: count == 0
      )

    ~H"""
    <div class={["flex gap-3", @class]}>
      <div class="flex h-64 shrink-0 flex-col justify-between text-xs text-base-content/45">
        <span :for={label <- @gridlines}>{label}</span>
      </div>

      <div class="min-w-0 flex-1">
        <div class="relative h-64">
          <div class="absolute inset-0 flex flex-col justify-between">
            <div :for={_line <- @gridlines} class="h-0 border-t border-base-200" />
          </div>

          <svg
            :if={not @empty?}
            viewBox="0 0 100 100"
            preserveAspectRatio="none"
            class="absolute inset-0 size-full overflow-visible"
            aria-hidden="true"
          >
            <polygon class="fill-blue-500/10" points={@area_points} />
            <polyline
              class="stroke-blue-500"
              points={@line_points}
              fill="none"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              vector-effect="non-scaling-stroke"
            />
          </svg>

          <span
            :for={point <- @plotted}
            class="absolute size-2.5 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-blue-500 bg-base-100"
            style={"left: #{fmt(point.x)}%; top: #{fmt(point.y)}%"}
          />
          <p
            :if={@empty?}
            class="absolute inset-0 flex items-center justify-center text-sm text-base-content/45"
          >
            No invoices in this period.
          </p>
        </div>

        <div class="relative mt-2 h-4">
          <span
            :for={point <- @plotted}
            class="absolute -translate-x-1/2 whitespace-nowrap text-xs text-base-content/60"
            style={"left: #{fmt(point.x)}%"}
          >
            {point.label}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # A single point has no span to spread across, so centre it rather than
  # dividing by zero.
  defp x_position(_i, 1), do: 50.0
  defp x_position(i, count), do: i / (count - 1) * 100

  defp fmt(number), do: :erlang.float_to_binary(number * 1.0, decimals: 2)

  # Rounds the axis up to a readable maximum divisible by four, so the five
  # gridline labels land on round numbers.
  #
  # The ladder is deliberately fine-grained. A coarse one (1/2/5/10 only) forces
  # a value of 21L onto a 40L axis, leaving the plot using half its height; the
  # intermediate steps keep the line filling the box.
  @step_multipliers [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]

  defp nice_max(max) when max <= 0, do: 4

  defp nice_max(max) do
    raw_step = max / 4
    magnitude = :math.pow(10, Float.floor(:math.log10(raw_step)))

    multiplier =
      Enum.find(@step_multipliers, 10, fn multiplier -> magnitude * multiplier >= raw_step end)

    step = trunc(Float.ceil(magnitude * multiplier))

    step * 4
  end

  # Indian short scale, matching how the rest of the app talks about money.
  defp axis_label(value) when value >= 10_000_000, do: "₹" <> short(value / 10_000_000) <> "Cr"
  defp axis_label(value) when value >= 100_000, do: "₹" <> short(value / 100_000) <> "L"
  defp axis_label(value) when value >= 1_000, do: "₹" <> short(value / 1_000) <> "K"
  defp axis_label(value), do: "₹#{value}"

  defp short(number) do
    number
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
  end

  @doc """
  Renders one labelled control in the filters panel.

  `type` is `"select"` or `"text"`; `options` is required for a select.
  """
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :type, :string, default: "select"
  attr :options, :list, default: []
  attr :placeholder, :string, default: nil

  def filter_field(assigns) do
    ~H"""
    <div>
      <label for={"filter-#{@name}"} class="mb-1.5 block text-xs font-medium text-base-content/60">
        {@label}
      </label>

      <select :if={@type == "select"} id={"filter-#{@name}"} name={@name} class={form_select_class()}>
        <option :for={option <- @options} value={option} selected={option == @value}>
          {option}
        </option>
      </select>

      <input
        :if={@type == "text"}
        type="text"
        id={"filter-#{@name}"}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        phx-debounce="300"
        class={form_input_class()}
      />
    </div>
    """
  end

  @doc """
  Renders one entry of the "Top Clients by Invoice Value" list.
  """
  attr :rank, :integer, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true

  def top_client_row(assigns) do
    ~H"""
    <li class="flex items-center justify-between gap-4 text-sm">
      <span class="flex min-w-0 items-center gap-2.5">
        <span class="w-4 shrink-0 text-xs text-base-content/45">{@rank}.</span>
        <span class="truncate text-base-content/80">{@name}</span>
      </span>
      <span class="whitespace-nowrap font-medium">{@value}</span>
    </li>
    """
  end

  @doc """
  Renders the dash the tax summary shows for a column that does not apply to
  that tax type, or the formatted amount when it does.
  """
  attr :amount, :integer, default: nil

  def tax_cell(assigns) do
    ~H"""
    <span :if={is_nil(@amount)} class="text-base-content/35">&mdash;</span>
    <span :if={@amount}>{QuantumBillingWeb.Format.rupees(@amount, decimals: 2)}</span>
    """
  end

  @doc """
  Renders the small refresh-style link that clears every filter.
  """
  def reset_link(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="reset_filters"
      class="mt-3 flex w-full items-center justify-center gap-1.5 text-xs font-medium text-base-content/60 transition-colors hover:text-base-content"
    >
      <.icon name="hero-arrow-path" class="size-3.5" /> Reset Filters
    </button>
    """
  end
end
