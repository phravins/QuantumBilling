defmodule QuantumBillingWeb.PageControllerTest do
  use QuantumBillingWeb.ConnCase

  test "GET / renders the dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Overview of your GST invoicing and compliance"
  end
end
