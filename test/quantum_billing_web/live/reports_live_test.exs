defmodule QuantumBillingWeb.ReportsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Reports

  setup :register_and_log_in_user

  # Assertions about figures moving as filters change need rows to aggregate,
  # and there are none until the invoices table exists. Those tests come back
  # with the schema; the aggregation logic itself stays covered by
  # QuantumBilling.ReportsTest, which supplies its own fixtures.

  describe "page" do
    test "renders every panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      assert html =~ "Analyze your business data and GST performance"
      assert html =~ "Invoice Value Trend"
      assert html =~ "Invoices by Status"
      assert html =~ "Filters"
      assert html =~ "Tax Summary (by Tax Type)"
      assert html =~ "Top Clients by Invoice Value"
    end

    test "renders the four metric cards, zeroed", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      assert html =~ "Total Invoices"
      assert html =~ "Total Taxable Value"
      assert html =~ "Total Tax Amount"
      assert html =~ "Total Invoice Value"
      assert html =~ ">0<"
    end

    test "defaults to the current year", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      assert html =~ Reports.range_label("This Year")
    end

    test "shows empty states across every panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      assert html =~ "No invoices in this period."
      assert html =~ "No invoices match these filters."
    end

    test "the trend chart degrades without drawing a broken plot", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      # No points means no line and no area, but the axis still renders.
      refute html =~ "<polyline"
      refute html =~ "<polygon"
      assert html =~ "₹"
    end

    test "serves no sample records", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      refute html =~ "V2V Technologies"
      refute html =~ "Insta Capital"
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/reports")
    end
  end

  describe "controls" do
    test "the filter form is present and accepts input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reports")

      html = view |> form("#reports-filters") |> render_change(%{"status" => "Cancelled"})

      assert html =~ "No invoices match these filters."
    end

    test "the date range control changes the displayed period", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reports")

      html =
        view
        |> element("a[phx-click=set_range][phx-value-range='This Month']")
        |> render_click()

      assert html =~ Reports.range_label("This Month")
    end

    test "reset restores the default period", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reports")

      view |> element("a[phx-click=set_range][phx-value-range='This Month']") |> render_click()

      restored = view |> element("button[phx-click=reset_filters]") |> render_click()

      assert restored =~ Reports.range_label("This Year")
    end

    test "the export link carries the active filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reports")

      html = view |> form("#reports-filters") |> render_change(%{"status" => "Cancelled"})

      assert html =~ "/reports/export?"
      assert html =~ "status=Cancelled"
    end
  end
end
