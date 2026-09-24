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

    # The draw-in used to be a dash: `stroke-dasharray: 1` over
    # `pathLength="1"`. Chrome ignores pathLength once `non-scaling-stroke` is
    # set and measures the dash in screen pixels instead, so the far end of a
    # wide chart stayed inside the gap and the trend line stopped short of its
    # last reading — on the finished chart, not only mid-animation. A clip that
    # sweeps across has no length to normalise, so it cannot do that.
    test "draws itself in with a clip, never a dash" do
      html = chart([1, 2, 3])

      assert html =~ ~s(<clipPath id="trend-sweep")
      assert html =~ ~s(class="qb-chart-sweep")
      assert html =~ ~s|clip-path="url(#trend-sweep)"|
      refute html =~ "pathLength"
      refute html =~ "stroke-dasharray"
    end

    # Every x the path visits. The readings sit on the frame at both ends
    # rather than inset from it, so the curve fills the plot instead of
    # leaving a dead margin down each side.
    defp path_xs(html) do
      [_all, d] = Regex.run(~r/class="qb-chart-line[^"]*"\s+d="([^"]+)"/, html)

      ~r/-?\d+(?:\.\d+)?/
      |> Regex.scan(d)
      |> Enum.map(fn [n] ->
        String.to_float(if String.contains?(n, "."), do: n, else: n <> ".0")
      end)
      |> Enum.take_every(2)
    end

    test "runs edge to edge across the plot" do
      xs = [10, 40, 20, 60] |> chart() |> path_xs()

      assert Enum.min(xs) == 0.0
      assert Enum.max(xs) == 100.0
    end

    # The labels used to be a row of equal cells, which puts a cell centre
    # under each point only when the points are inset. They are positioned
    # off the same fractions as the curve now, and the two ends pin their
    # own outer edge so neither hangs off the card.
    test "labels sit under the points they name" do
      html = chart([10, 40, 20])

      assert html =~ ~s(style="left: 0.00%")
      assert html =~ ~s(style="left: 50.00%")
      assert html =~ ~s(style="left: 100.00%")
      assert html =~ "translate-x-0"
      assert html =~ "-translate-x-full"
    end

    # One reading is a chart with no span to spread across. Dividing by the
    # gap count would be a division by zero.
    test "a single reading plots without dividing by zero" do
      assert [7] |> chart() |> path_xs() == [50.0]
    end
  end
end
