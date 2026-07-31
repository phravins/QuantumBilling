defmodule QuantumBillingWeb.PageControllerTest do
  use QuantumBillingWeb.ConnCase

  setup :register_and_log_in_user

  test "GET / renders the dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Overview of your GST invoicing and compliance"
  end

  test "the dashboard shows empty states instead of invented figures", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "No invoice data yet"
    assert html =~ "No invoices yet"
    assert html =~ "No upcoming due dates"
  end

  test "the dashboard serves no sample records", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    refute html =~ "V2V Technologies"
    refute html =~ "INV-2024-"
    refute html =~ "15,489"
  end
end
