defmodule QuantumBillingWeb.ComplianceLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Compliance
  alias QuantumBilling.Settings

  @gstin "27AABCA1234A1Z5"

  defp register_gstin(gstin \\ @gstin) do
    Settings.update_section(
      Settings.get_organization(),
      %{"gstin" => gstin, "company_name" => "Northwind Supply Co"},
      :general
    )
  end

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

      assert html =~ "Total Tracked"
      assert html =~ "Completed"
      assert html =~ "Pending"
      assert html =~ "Overdue"
      assert html =~ Compliance.financial_year_label(Date.utc_today())
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/compliance")
    end
  end

  # Without a GSTIN the panels say what is missing.
  describe "with no GSTIN on file" do
    test "the table says what is missing, rather than blaming the filters", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "No GST registration on file"
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
      assert html =~ "Filing deadlines appear here once a GSTIN is saved"
      refute html =~ "Every obligation for this year is filed."
    end

    test "no obligation offers an acknowledgement to download", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      refute html =~ "acknowledgement"
    end
  end

  # With a registration on file the page has something to be about: the returns
  # that registration owes, on the dates the statute sets them.
  describe "with a GSTIN on file" do
    setup do
      {:ok, organization} = register_gstin()

      %{organization: organization}
    end

    test "the returns for the registration are tracked", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "GSTR-1"
      assert html =~ "GSTR-3B"
      refute html =~ "No GST registration on file"
    end

    # A composition dealer and a regular taxpayer do not file the same forms,
    # so the page has to read the scheme rather than list everything the law
    # knows about.
    test "a composition dealer gets CMP-08 instead", %{conn: conn, organization: organization} do
      {:ok, _organization} =
        Settings.update_section(organization, %{"composition_scheme" => "true"}, :tax)

      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "CMP-08"
      refute html =~ "GSTR-3B"
    end

    test "the upcoming rail lists what falls due next", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      refute html =~ "Nothing due"
    end
  end

  # A return is marked filed from its detail panel; type and period come from
  # the open panel, never from the form.
  describe "marking a return filed" do
    setup %{conn: conn} do
      {:ok, _organization} = register_gstin()

      # The earliest return this year: Overdue on most days, Pending in the
      # first days of April. Either way Undo must put back what was there.
      return =
        Date.utc_today()
        |> Compliance.tracked_obligations(%{gstin: @gstin})
        |> Enum.min_by(& &1.due_date, Date)

      {:ok, view, _html} = live(conn, ~p"/compliance")

      view
      |> element("#view-obligation-#{return.type}-#{return.due_date}")
      |> render_click()

      %{view: view, return: return}
    end

    defp status_text(view) do
      view |> element("#obligation-detail-status") |> render()
    end

    test "the panel offers it for a return that is not filed", %{view: view, return: return} do
      assert status_text(view) =~ return.status
      assert has_element?(view, "#mark-filed-button")
      refute has_element?(view, "#undo-filed-button")
    end

    test "saving marks it Filed, and Undo puts the old status back", ctx do
      %{view: view, return: return} = ctx

      view |> element("#mark-filed-button") |> render_click()
      assert has_element?(view, "#filing-form")

      view
      |> form("#filing-form",
        filing: %{
          filed_on: Date.to_iso8601(Date.utc_today()),
          arn: "aa27 0424 1234 567"
        }
      )
      |> render_submit()

      refute has_element?(view, "#filing-form")
      assert status_text(view) =~ "Filed"
      assert view |> element("#obligation-detail-arn") |> render() =~ "AA270424123456"
      assert has_element?(view, "#undo-filed-button")

      view |> element("#undo-filed-button") |> render_click()

      assert status_text(view) =~ return.status
      refute status_text(view) =~ "Filed"
      assert has_element?(view, "#mark-filed-button")
    end

    test "a date after today is shown as an error and nothing is saved", %{view: view} do
      view |> element("#mark-filed-button") |> render_click()

      view
      |> form("#filing-form", filing: %{filed_on: Date.to_iso8601(Date.add(Date.utc_today(), 3))})
      |> render_submit()

      assert has_element?(view, "#filing-form")
      assert render(view) =~ "can&#39;t be in the future"
      assert Compliance.list_filings() == %{}
    end

    test "cancel closes the form without saving", %{view: view} do
      view |> element("#mark-filed-button") |> render_click()
      view |> element("#filing-cancel") |> render_click()

      refute has_element?(view, "#filing-form")
      assert has_element?(view, "#mark-filed-button")
      assert Compliance.list_filings() == %{}
    end
  end

  describe "clicking a day" do
    setup %{conn: conn} do
      {:ok, _organization} = register_gstin()

      today = Date.utc_today()

      # Taken from the schedule, so the test does not depend on the calendar.
      due =
        Date.utc_today()
        |> Compliance.tracked_obligations(%{gstin: @gstin})
        |> Enum.map(& &1.due_date)
        |> Enum.find(&(&1.year == today.year and &1.month == today.month))

      {:ok, view, _html} = live(conn, ~p"/compliance")

      %{view: view, due: due}
    end

    defp day(view, date), do: element(view, "button[phx-value-date='#{Date.to_iso8601(date)}']")

    test "narrows the task list to that date", %{view: view, due: due} do
      html = view |> day(due) |> render_click()

      assert html =~ "Due #{Calendar.strftime(due, "%d %b %Y")}"

      rows = Compliance.on_date(Compliance.tracked_obligations(due, %{gstin: @gstin}), due)
      assert rows != []

      for type <- Enum.map(rows, & &1.type), do: assert(html =~ type)
    end

    test "clicking the same day again clears the narrowing", %{view: view, due: due} do
      view |> day(due) |> render_click()
      html = view |> day(due) |> render_click()

      refute html =~ "Due #{Calendar.strftime(due, "%d %b %Y")}"
    end

    test "the chip clears it too", %{view: view, due: due} do
      view |> day(due) |> render_click()

      html = view |> element("button[phx-click=clear_day]") |> render_click()

      refute html =~ "Due #{Calendar.strftime(due, "%d %b %Y")}"
    end

    # A day with nothing due is not a filter worth applying, so it is not a
    # button you can press into an empty table.
    test "a day with nothing due is not clickable", %{view: view, due: due} do
      obligations = Compliance.tracked_obligations(due, %{gstin: @gstin})

      empty =
        Date.range(Date.beginning_of_month(due), Date.end_of_month(due))
        |> Enum.find(&(Compliance.on_date(obligations, &1) == []))

      assert has_element?(view, "button[phx-value-date='#{Date.to_iso8601(empty)}'][disabled]")
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
      assert html =~ "No GST registration on file"
    end
  end

  describe "status filter" do
    test "narrows without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      html = render_click(view, "filter_status", %{"status" => "Filed"})

      assert html =~ "No GST registration on file"
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
