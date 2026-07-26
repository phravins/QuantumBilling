defmodule QuantumBillingWeb.EWayBillsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders the first page of e-way bills", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ "Track consignments and generate new e-way bills"
    assert html =~ "Showing 1 to 10 of 60 entries"
    assert length(row_numbers(html)) == 10
    assert html =~ "V2V Technologies"
    assert html =~ "Mumbai"
  end

  test "links to the generate form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ ~s(href="/e-way-bills/new")
    assert html =~ "Generate New E-Way Bill"
  end

  test "search narrows results by document number", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    html = view |> form("#ewb-search", %{"q" => "INV-2024-15489"}) |> render_change()

    assert html =~ "Showing 1 to 1 of 1 entries"
    assert length(row_numbers(html)) == 1
  end

  test "search matches on the consignee name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    html = view |> form("#ewb-search", %{"q" => "Vertex Pharma"}) |> render_change()

    assert html =~ "Vertex Pharma"
    refute html =~ "V2V Technologies"
  end

  test "status filter shows only matching rows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    html = render_click(view, "filter_status", %{"status" => "Cancelled"})

    assert html =~ "Showing 1 to 6 of 6 entries"
    assert count_occurrences(html, ">Cancelled<") == 6
  end

  test "sorting by value toggles between ascending and descending", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    asc = view |> render_click("sort", %{"field" => "value"}) |> row_values()
    assert asc == Enum.sort(asc, :asc)

    desc = view |> render_click("sort", %{"field" => "value"}) |> row_values()
    assert desc == Enum.sort(desc, :desc)
    assert asc != desc
  end

  test "pagination moves to the next page with different rows", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/e-way-bills")

    page1 = row_numbers(html)
    page2 = render_click(view, "paginate", %{"page" => "2"})

    assert page2 =~ "Showing 11 to 20 of 60 entries"
    assert row_numbers(page2) != page1
  end

  defp row_numbers(html) do
    ~r/id="ewb-(\d+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, no] -> no end)
  end

  # The value column is the only one rendered with the two-decimal rupee format.
  defp row_values(html) do
    ~r/₹ ([\d,]+)\.00</
    |> Regex.scan(html)
    |> Enum.map(fn [_, v] -> v |> String.replace(",", "") |> String.to_integer() end)
  end

  defp count_occurrences(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
