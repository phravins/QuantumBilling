defmodule QuantumBillingWeb.ReportsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Reports

  setup :register_and_log_in_user

  describe "page" do
    test "renders the four metric cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      assert html =~ "Analyze your business data and GST performance"
      assert html =~ "Total Invoices"
      assert html =~ "Total Taxable Value"
      assert html =~ "Total Tax Amount"
      assert html =~ "Total Invoice Value"
    end

    test "renders every panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      assert html =~ "Invoice Value Trend"
      assert html =~ "Invoices by Status"
      assert html =~ "Filters"
      assert html =~ "Tax Summary (by Tax Type)"
      assert html =~ "Top Clients by Invoice Value"
    end

    test "shows the whole year by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      assert html =~ "01 Jan 2024 - 31 Dec 2024"
      assert html =~ ">256<"
    end

    test "charts carry colour, the rest of the page does not", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports")

      # Donut ring and trend line.
      assert html =~ "stroke-blue-500"
      assert html =~ "fill-blue-500/10"

      # The primary action stays monochrome rather than the design's blue.
      assert html =~ "bg-primary"
      refute html =~ "bg-blue-600"
    end

    test "requires authentication" do
      conn = build_conn()
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/reports")
    end
  end

  describe "filters" do
    test "narrowing by status changes the figures", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/reports")

      assert html =~ ">256<"

      filtered =
        view
        |> form("#reports-filters")
        |> render_change(%{"status" => "Cancelled"})

      assert filtered =~ ">17<"
      refute filtered =~ ">256<"
    end

    test "narrowing by client changes the figures", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reports")

      expected =
        Reports.invoices()
        |> Reports.filter(%{date_range: "This Year", client: "Insta Capital"})
        |> length()

      html =
        view
        |> form("#reports-filters")
        |> render_change(%{"client" => "Insta Capital"})

      assert html =~ ">#{expected}<"
    end

    test "a GSTIN with no match empties every panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reports")

      html =
        view
        |> form("#reports-filters")
        |> render_change(%{"gstin" => "NOSUCHGSTIN"})

      assert html =~ "No invoices match these filters."
      assert html =~ "No invoices in this period."
    end

    test "reset restores the defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reports")

      narrowed =
        view
        |> form("#reports-filters")
        |> render_change(%{"status" => "Cancelled"})

      assert narrowed =~ ">17<"

      restored = view |> element("button[phx-click=reset_filters]") |> render_click()

      assert restored =~ ">256<"
      assert restored =~ "01 Jan 2024 - 31 Dec 2024"
    end

    test "the date range moves every panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reports")

      html =
        view
        |> element("a[phx-click=set_range][phx-value-range='This Month']")
        |> render_click()

      assert html =~ "01 May 2024 - 31 May 2024"
      refute html =~ ">256<"
    end
  end

  describe "export link" do
    test "carries the active filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reports")

      html =
        view
        |> form("#reports-filters")
        |> render_change(%{"status" => "Cancelled"})

      assert html =~ "/reports/export?"
      assert html =~ "status=Cancelled"
    end
  end
end
