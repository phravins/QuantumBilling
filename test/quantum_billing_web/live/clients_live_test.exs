defmodule QuantumBillingWeb.ClientsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders the first page of clients", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    assert html =~ "Manage your clients and their details"
    assert html =~ "Showing 1 to 10 of 128 entries"
    assert length(row_ids(html)) == 10
    assert html =~ "V2V Technologies"
    assert html =~ "27AAACPJ8542D1ZS"
    # outstanding renders with paise and a space after the rupee sign
    assert html =~ "₹ 15,000.00"
  end

  test "renders the four summary tiles", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    assert html =~ "Total Clients"
    assert html =~ "All time"
    assert html =~ "Active Clients"
    assert html =~ "87.5% of total"
    assert html =~ "Inactive Clients"
    assert html =~ "8.6% of total"
    assert html =~ "Blocked Clients"
    assert html =~ "3.9% of total"
    assert metric_values(html) == ["128", "112", "11", "5"]
  end

  test "search narrows results by name, GSTIN and email", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    by_name = view |> form("#clients-search", %{"q" => "DreamNest"}) |> render_change()
    assert by_name =~ "Showing 1 to 1 of 1 entries"
    assert by_name =~ "DreamNest Builders"
    refute by_name =~ "V2V Technologies"

    by_gstin = view |> form("#clients-search", %{"q" => "29AAQCS1111L1ZP"}) |> render_change()
    assert by_gstin =~ "SoftSphere Solutions"
    assert length(row_ids(by_gstin)) == 1

    by_email =
      view |> form("#clients-search", %{"q" => "admin@instacapital.in"}) |> render_change()

    assert by_email =~ "Insta Capital"
    assert length(row_ids(by_email)) == 1
  end

  test "status filter shows only matching clients", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    html = render_click(view, "filter_status", %{"status" => "Blocked"})

    assert html =~ "Showing 1 to 5 of 5 entries"
    assert length(row_ids(html)) == 5
    assert count_occurrences(html, ~s(text-rose-700">Blocked<)) == 5
    refute html =~ ~s(text-emerald-700">Active<)
  end

  test "summary tiles are filter shortcuts and keep all-time totals", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/clients")

    # the Blocked tile carries the filter payload
    assert html =~ ~s(phx-value-status="Blocked")

    filtered = render_click(view, "filter_status", %{"status" => "Inactive"})

    assert filtered =~ "Showing 1 to 10 of 11 entries"
    # tiles still report the whole client base, not the filtered subset
    assert metric_values(filtered) == ["128", "112", "11", "5"]
    assert filtered =~ "87.5% of total"
  end

  test "sorting by client name toggles between ascending and descending", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    asc = view |> render_click("sort", %{"field" => "name"}) |> row_names()
    assert asc == Enum.sort(asc, :asc)

    desc = view |> render_click("sort", %{"field" => "name"}) |> row_names()
    assert desc == Enum.sort(desc, :desc)
    assert asc != desc
  end

  test "sorting by outstanding orders numerically", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    asc = view |> render_click("sort", %{"field" => "outstanding"}) |> row_amounts()
    assert asc == Enum.sort(asc, :asc)

    desc = view |> render_click("sort", %{"field" => "outstanding"}) |> row_amounts()
    assert desc == Enum.sort(desc, :desc)
  end

  test "default view keeps insertion order with no active sort arrow", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    # screenshot order: V2V first, Bright Future last on page 1
    assert List.first(row_ids(html)) == 1
    assert List.last(row_ids(html)) == 10
    # both sortable headers show the neutral indicator until a sort is chosen
    assert count_occurrences(html, "hero-chevron-up-down") == 2
  end

  test "pagination walks to the next and final page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/clients")

    page1 = row_ids(html)

    page2 = render_click(view, "paginate", %{"page" => "2"})
    assert page2 =~ "Showing 11 to 20 of 128 entries"
    assert row_ids(page2) != page1

    last = render_click(view, "paginate", %{"page" => "13"})
    assert last =~ "Showing 121 to 128 of 128 entries"
    assert length(row_ids(last)) == 8
  end

  defp row_ids(html) do
    ~r/id="client-(\d+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> String.to_integer(id) end)
  end

  defp row_names(html) do
    ~r/<span class="font-medium">([^<]+)<\/span>/
    |> Regex.scan(html)
    |> Enum.map(fn [_, name] -> name end)
  end

  defp row_amounts(html) do
    ~r/₹ ([\d,]+)\.00/
    |> Regex.scan(html)
    |> Enum.map(fn [_, amt] -> amt |> String.replace(",", "") |> String.to_integer() end)
  end

  defp metric_values(html) do
    ~r/<span class="block text-2xl font-semibold tracking-tight">([^<]+)<\/span>/
    |> Regex.scan(html)
    |> Enum.map(fn [_, v] -> v end)
  end

  defp count_occurrences(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
