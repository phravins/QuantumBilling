defmodule QuantumBillingWeb.InvoicesLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the first page of invoices", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/invoices")

    assert html =~ "Manage and track all your GST invoices"
    assert html =~ "Showing 1 to 10 of 98 entries"
    assert count_rows(html) == 10
  end

  test "search filters rows by client name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices")

    html = view |> form("form", %{"q" => "V2V Technologies"}) |> render_change()

    assert html =~ "V2V Technologies"
    assert html =~ "Showing 1 to 1 of 1 entries"
    assert count_rows(html) == 1
  end

  test "search filters rows by invoice number", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices")

    html = view |> form("form", %{"q" => "INV-2024-15481"}) |> render_change()

    assert html =~ "Cancelled"
    assert html =~ "Showing 1 to 1 of 1 entries"
  end

  test "status filter shows only matching-status rows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices")

    html = render_click(view, "filter_status", %{"status" => "Draft"})

    assert html =~ "Showing 1 to 1 of 1 entries"
    assert html =~ "Arch Info-Tech"
    refute html =~ "V2V Technologies"
  end

  test "sorting toggles direction and reorders rows", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/invoices")

    assert row_order(html) == Enum.sort(row_order(html), :desc)

    asc_html = render_click(view, "sort", %{"field" => "invoice_date"})
    assert row_order(asc_html) == Enum.sort(row_order(asc_html))

    desc_html = render_click(view, "sort", %{"field" => "invoice_date"})
    assert row_order(desc_html) == Enum.sort(row_order(desc_html), :desc)
  end

  test "pagination moves to the next page with different rows", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/invoices")

    page1_rows = row_order(html)

    page2_html = render_click(view, "paginate", %{"page" => "2"})
    page2_rows = row_order(page2_html)

    assert page2_html =~ "Showing 11 to 20 of 98 entries"
    assert page1_rows != page2_rows
  end

  defp count_rows(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("tbody tr")
    |> length()
  end

  defp row_order(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("tbody tr")
    |> Enum.map(fn row -> row |> Floki.find("td:first-child") |> Floki.text() end)
  end
end
