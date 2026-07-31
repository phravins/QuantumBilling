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
    # `palette` exists so the Reports page can show a coloured ring. Its default
    # must stay :mono, or the dashboard silently changes appearance too.
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
end
