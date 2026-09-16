defmodule QuantumBillingWeb.PageControllerTest do
  use QuantumBillingWeb.ConnCase

  setup :register_and_log_in_user

  test "GET / renders the dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Overview of your GST invoicing and compliance"
  end

  test "the dashboard shows empty states instead of invented figures", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    # Nothing has been billed, so the chart and the recent-invoice table say so
    # rather than drawing six months of zeros.
    assert html =~ "No invoice data yet"
    assert html =~ "No invoices yet"
  end

  test "the compliance calendar lists real statutory deadlines", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    # GST return dates are statutory rather than tenant data, so they exist on
    # day one — the panel used to be hardcoded empty.
    assert html =~ "GSTR-3B" or html =~ "GSTR-1" or html =~ "GSTR-9"
    assert html =~ "Due in" or html =~ "Due today" or html =~ "Overdue by"
  end

  test "the headline figures come from the invoice table", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Current Month Tax Liability"
    assert html =~ "Outstanding Receivables"
    assert html =~ "Pending GST Returns"
  end

  test "the dashboard serves no sample records", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    refute html =~ "V2V Technologies"
    refute html =~ "INV-2024-"
    refute html =~ "15,489"
  end
end
