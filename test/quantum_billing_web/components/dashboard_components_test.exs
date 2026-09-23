defmodule QuantumBillingWeb.DashboardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias QuantumBillingWeb.DashboardComponents

  @segments [
    %{label: "Generated", value: 8, tone: :strong},
    %{label: "Pending", value: 3, tone: :medium},
    %{label: "Failed", value: 2, tone: :soft},
    %{label: "Cancelled", value: 1, tone: :faint}
  ]

  defp donut(assigns) do
    render_component(&DashboardComponents.donut_chart/1, assigns)
  end

  describe "donut_chart/1 palette" do
    # `palette` is opt-in: a caller that does not ask for colour gets the
    # monochrome ramp. The dashboard and Reports both pass `:color` now, but
    # the default is what every other caller inherits, so it is pinned here.
    test "defaults to monochrome" do
      html = donut(segments: @segments, total: 14)

      assert html =~ "stroke-base-content"
      refute html =~ "stroke-blue-500"
      refute html =~ "stroke-amber-500"
      refute html =~ "stroke-rose-500"
    end

    test "renders colour only when asked" do
      html = donut(segments: @segments, total: 14, palette: :color)

      assert html =~ "stroke-blue-500"
      assert html =~ "stroke-amber-500"
      assert html =~ "stroke-rose-500"
    end

    test "legend dots follow the ring" do
      assert donut(segments: @segments, total: 14) =~ "bg-base-content"
      assert donut(segments: @segments, total: 14, palette: :color) =~ "bg-blue-500"
    end
  end

  describe "donut_chart/1 percentages" do
    test "are hidden by default" do
      refute donut(segments: @segments, total: 14) =~ "%)"
    end

    test "are shown on request and add up" do
      html = donut(segments: @segments, total: 14, show_percent: true)

      # 8 of 14 is 57.1%
      assert html =~ "57.1%"
    end
  end

  describe "area_chart/1 curve" do
    defp chart(values) do
      render_component(&DashboardComponents.area_chart/1,
        id: "trend",
        series: [%{label: "Value", tone: :blue, values: values}],
        labels: Enum.map(1..length(values), &"M#{&1}"),
        max: Enum.max(values),
        axis_labels: ~w(4 3 2 1 0)
      )
    end

    # Every y the path visits, control points included. A bezier stays inside
    # the box its four points span, so bounding those bounds the curve.
    defp path_ys(html) do
      [_all, d] = Regex.run(~r/class="qb-chart-line[^"]*"\s+d="([^"]+)"/, html)

      ~r/-?\d+(?:\.\d+)?/
      |> Regex.scan(d)
      |> Enum.map(fn [n] ->
        String.to_float(if String.contains?(n, "."), do: n, else: n <> ".0")
      end)
      |> Enum.drop(1)
      |> Enum.take_every(2)
    end

    # The reason the plotter is monotone rather than Catmull-Rom. Around a
    # spike, Catmull-Rom overshoots: the line dipped below the axis between two
    # positive months and bulged over the top gridline after a quiet one,
    # drawing revenue that was never invoiced.
    test "never leaves the plot box, however spiky the readings" do
      for values <- [
            [0, 5, 4, 90, 3, 3, 40, 0],
            [100, 0, 100, 0, 100],
            [1, 1, 1, 80, 1, 1],
            [0, 0, 0, 0, 7]
          ] do
        ys = values |> chart() |> path_ys()

        assert Enum.min(ys) >= -0.01, "#{inspect(values)} drew above the top gridline"
        assert Enum.max(ys) <= 100.01, "#{inspect(values)} drew below the axis"
      end
    end

    test "a flat run stays flat" do
      ys = [40, 40, 40, 40] |> chart() |> path_ys()

      assert Enum.all?(ys, &(abs(&1 - 0.0) < 0.01)),
             "a level series wobbled: #{inspect(ys)}"
    end

    # The stroke is dashed to animate itself in, and `non-scaling-stroke` makes
    # the browser measure that dash in screen pixels. Without pathLength the
    # dash is a fixed length against a chart of any width, which is what left
    # the tail of a wide trend line permanently in the gap.
    test "normalises its length so the draw-in covers the whole line" do
      assert [1, 2, 3] |> chart() =~ ~s(pathLength="1")
    end
  end
end
