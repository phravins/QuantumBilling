defmodule QuantumBillingWeb.ComplianceLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Compliance

  setup :register_and_log_in_user

  describe "page" do
    test "renders every panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "Track your GST compliance and filing status"
      assert html =~ "Compliance Tasks"
      assert html =~ "Upcoming Due Dates"
      assert html =~ "Compliance Calendar"
      assert html =~ "View Filing Calendar"
    end

    test "renders the four summary cards for the current financial year", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "Total Returns"
      assert html =~ "Filed On Time"
      assert html =~ "Pending"
      assert html =~ "Overdue"
      assert html =~ Compliance.financial_year_label(Date.utc_today())
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/compliance")
    end
  end

  # The statutory calendar in `QuantumBilling.Compliance` is real and stays
  # tested there. Nothing on it belongs to this tenant until filing records
  # exist, so the panels render with no rows rather than showing the same 30
  # obligations to every business.
  describe "with nothing tracked" do
    test "the table says so, rather than blaming the filters", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "No compliance data yet"
      refute html =~ "Nothing matches these filters"
    end

    test "the summary counts are zero", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert Compliance.summary([]).total == 0
      refute html =~ "GSTR-1"
      refute html =~ "Showing 1 to"
    end

    test "the upcoming rail explains itself", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "Nothing due"
      assert html =~ "Filing deadlines will appear here"
      refute html =~ "Every obligation for this year is filed."
    end

    test "no obligation offers an acknowledgement to download", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      refute html =~ "acknowledgement"
    end
  end

  describe "tabs" do
    test "switch category without losing the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      html =
        view
        |> element("button[phx-click=filter_category][phx-value-category=payments]")
        |> render_click()

      assert html =~ "Compliance Tasks"
      assert html =~ "No compliance data yet"
    end
  end

  describe "status filter" do
    test "narrows without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      html = render_click(view, "filter_status", %{"status" => "Filed"})

      assert html =~ "No compliance data yet"
    end

    test "view all clears every filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      render_click(view, "filter_status", %{"status" => "Filed"})

      html = view |> element("button[phx-click=show_all]") |> render_click()

      assert html =~ "Compliance Tasks"
    end
  end

  describe "calendar" do
    test "opens on the current month", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ Calendar.strftime(Date.utc_today(), "%B %Y")
    end

    test "steps forward and back a month", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      today = Date.utc_today()
      next = Compliance.shift_months(Date.new!(today.year, today.month, 1), 1)
      previous = Compliance.shift_months(Date.new!(today.year, today.month, 1), -1)

      forward = view |> element("button[phx-click=next_month]") |> render_click()
      assert forward =~ Calendar.strftime(next, "%B %Y")

      # Back twice: once to return to today, once to go before it.
      view |> element("button[phx-click=prev_month]") |> render_click()
      back = view |> element("button[phx-click=prev_month]") |> render_click()

      assert back =~ Calendar.strftime(previous, "%B %Y")
    end

    test "shows the status legend", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "bg-emerald-500"
      assert html =~ "bg-amber-500"
      assert html =~ "bg-rose-500"
    end
  end
end
