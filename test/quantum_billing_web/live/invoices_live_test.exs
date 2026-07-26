defmodule QuantumBillingWeb.InvoicesLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders the first page of invoices", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/invoices")

    assert html =~ "Manage and track all your GST invoices"
    assert html =~ "Showing 1 to 10 of 98 entries"
    assert length(row_seqs(html)) == 10
  end

  test "search narrows results to rows matching the client name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices")

    html = view |> form("#invoice-search", %{"q" => "PressuCare"}) |> render_change()

    rows = row_seqs(html)
    assert 15485 in rows
    assert length(rows) < 10
    refute html =~ "V2V Technologies"
  end

  test "search matches on invoice number", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices")

    html = view |> form("#invoice-search", %{"q" => "INV-2024-15481"}) |> render_change()

    assert html =~ "Showing 1 to 1 of 1 entries"
    assert row_seqs(html) == [15481]
    assert html =~ "Cancelled"
  end

  test "status filter shows only matching-status rows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices")

    html = render_click(view, "filter_status", %{"status" => "Draft"})

    assert html =~ "Showing 1 to 10 of 10 entries"
    assert html =~ "Arch Info-Tech"
    refute html =~ "V2V Technologies"
    # one badge per visible row, and no other status badge on the page
    assert count_occurrences(html, ~s(text-base-content/70">Draft<)) == 10
    refute html =~ ~s(text-emerald-700">)
  end

  test "sorting by invoice number toggles between ascending and descending", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices")

    asc = view |> render_click("sort", %{"field" => "seq"}) |> row_seqs()
    assert asc == Enum.sort(asc, :asc)

    desc = view |> render_click("sort", %{"field" => "seq"}) |> row_seqs()
    assert desc == Enum.sort(desc, :desc)
    assert asc != desc
  end

  test "sorting by date orders rows chronologically", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/invoices")

    # default sort is invoice_date desc
    dates = row_dates(html)
    assert dates == Enum.sort(dates, {:desc, Date})

    asc_dates = view |> render_click("sort", %{"field" => "invoice_date"}) |> row_dates()
    assert asc_dates == Enum.sort(asc_dates, {:asc, Date})
  end

  test "pagination moves to the next page with different rows", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/invoices")

    page1 = row_seqs(html)
    page2_html = render_click(view, "paginate", %{"page" => "2"})

    assert page2_html =~ "Showing 11 to 20 of 98 entries"
    assert row_seqs(page2_html) != page1
  end

  defp row_seqs(html) do
    ~r/id="invoice-(\d+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, seq] -> String.to_integer(seq) end)
  end

  # grabs the first <td> date cell of each row (the Invoice Date column)
  defp row_dates(html) do
    ~r/<td[^>]*>(\d{2} \w{3} \d{4})<\/td>/
    |> Regex.scan(html)
    |> Enum.map(fn [_, d] -> Date.from_iso8601!(to_iso(d)) end)
    |> Enum.take_every(2)
  end

  defp to_iso(<<d::binary-2, " ", mon::binary-3, " ", y::binary-4>>) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    m = Enum.find_index(months, &(&1 == mon)) + 1
    "#{y}-#{String.pad_leading(to_string(m), 2, "0")}-#{d}"
  end

  defp count_occurrences(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
