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

    test "lists the statutory obligations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "GSTR-1"
      assert html =~ "GSTR-3B"
      assert html =~ "CMP-08"
      assert html =~ "GSTR-9"
      assert html =~ "Monthly Return"
      assert html =~ "Showing 1 to 30 of 30 entries"
    end

    test "nothing is filed while there are no filing records", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      # The download action only exists for a filed return.
      refute html =~ "acknowledgement"
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/compliance")
    end
  end

  describe "tabs" do
    test "narrow the table by category", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      payments =
        view
        |> element("button[phx-click=filter_category][phx-value-category=payments]")
        |> render_click()

      assert payments =~ "Showing 1 to 4 of 4 entries"

      # Scoped to table rows: the Upcoming Due Dates rail deliberately keeps
      # showing what falls due next across every category, so asserting on the
      # whole page would be testing the wrong thing.
      assert has_element?(view, "tr[id^='obligation-CMP-08']")
      refute has_element?(view, "tr[id^='obligation-GSTR-3B']")
      refute has_element?(view, "tr[id^='obligation-GSTR-1']")
    end

    test "the other-compliances tab isolates the reconciliation statement", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      html =
        view
        |> element("button[phx-click=filter_category][phx-value-category=other]")
        |> render_click()

      assert html =~ "GSTR-9C"
      assert html =~ "Showing 1 to 1 of 1 entries"
    end

    test "all restores the full list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      view
      |> element("button[phx-click=filter_category][phx-value-category=payments]")
      |> render_click()

      html =
        view
        |> element("button[phx-click=filter_category][phx-value-category=all]")
        |> render_click()

      assert html =~ "Showing 1 to 30 of 30 entries"
    end
  end

  describe "status filter" do
    test "narrows to a single status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      html = render_click(view, "filter_status", %{"status" => "Filed"})

      # Nothing is filed yet, so this is the empty state.
      assert html =~ "Nothing matches these filters"
    end

    test "combines with the tabs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      view
      |> element("button[phx-click=filter_category][phx-value-category=payments]")
      |> render_click()

      html = render_click(view, "filter_status", %{"status" => "Filed"})

      assert html =~ "Nothing matches these filters"
    end

    test "view all clears every filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      render_click(view, "filter_status", %{"status" => "Filed"})

      html = view |> element("button[phx-click=show_all]") |> render_click()

      assert html =~ "Showing 1 to 30 of 30 entries"
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

  describe "row detail" do
    test "opens and closes the obligation detail", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      row = Compliance.obligations(Date.utc_today()) |> hd()

      opened =
        view
        |> element(
          "button[phx-click=show_detail][phx-value-type='#{row.type}'][phx-value-due='#{row.due_date}']"
        )
        |> render_click()

      assert opened =~ "Statutory rule"
      assert opened =~ "Due date"

      closed = view |> element("button[phx-click=close_detail]") |> render_click()

      refute closed =~ "Statutory rule"
    end
  end
end
