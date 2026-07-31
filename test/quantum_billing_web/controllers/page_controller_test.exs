defmodule QuantumBillingWeb.PageControllerTest do
  use QuantumBillingWeb.ConnCase

  setup :register_and_log_in_user

  test "GET / renders the dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Overview of your GST invoicing and compliance"
  end

  # `donut_chart/1` gained a `palette` attribute so the Reports page could show
  # a coloured ring. Its default must stay `:mono`, or this page silently
  # changes appearance too.
  test "the dashboard donut stays monochrome", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "stroke-base-content"
    refute html =~ "stroke-blue-500"
    refute html =~ "stroke-amber-500"
    refute html =~ "stroke-rose-500"
  end
end
