defmodule QuantumBillingWeb.ReportsComponents do
  @moduledoc """
  Building blocks for the Reports page: the invoice-value trend chart and the
  labelled controls in the filters panel.

  The trend chart itself is `DashboardComponents.area_chart/1`; what lives here
  is the axis scaling that decides where this page's gridlines land, and the
  empty state for a filter that matched nothing.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]
  import QuantumBillingWeb.SharedComponents, only: [form_select_class: 0, form_input_class: 0]

  alias QuantumBillingWeb.DashboardComponents

  @doc """
  Renders the invoice-value trend from a list of `%{label:, value:}` maps.

  A thin wrapper over `DashboardComponents.area_chart/1` rather than a second
  plotter: the dashboard and this page draw the same kind of picture, and when
  they were two implementations they disagreed about smoothing, about where
  the first point sits, and about how an empty period reads.
  """
  attr :points, :list, required: true
  attr :class, :any, default: nil

  def line_chart(assigns) do
    values = Enum.map(assigns.points, & &1.value)
    max = values |> Enum.max(fn -> 0 end) |> nice_max()

    assigns =
      assign(assigns,
        max: max,
        labels: Enum.map(assigns.points, & &1.label),
        series: [%{label: "Invoice value", tone: :blue, values: values}],
        axis_labels: Enum.map(4..0//-1, &DashboardComponents.money_axis_label(div(max, 4) * &1)),
        empty?: assigns.points == []
      )

    ~H"""
    <div class={["flex flex-col", @class]}>
      <DashboardComponents.area_chart
        :if={not @empty?}
        class="min-h-0 flex-1"
        id="reports-value-trend"
        series={@series}
        labels={@labels}
        max={@max}
        axis_labels={@axis_labels}
        format={&DashboardComponents.money_axis_label/1}
      />
      <p
        :if={@empty?}
        class="flex min-h-56 flex-1 items-center justify-center text-sm text-base-content/45"
      >
        No invoices in this period.
      </p>
    </div>
    """
  end

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
