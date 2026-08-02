defmodule QuantumBillingWeb.ComplianceLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  describe "page" do
    test "renders the heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "Track your GST compliance and filing status"
    end

    test "shows the empty state while nothing is tracked", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      assert html =~ "No compliance data yet"
      assert html =~ "GST filing obligations will appear here"
    end

    # The statutory calendar itself is real and still covered by
    # `QuantumBilling.ComplianceTest`. It has no tenant data to attach to until
    # the filings table exists, so none of it reaches the page — showing the
    # same 30 rows to every business would read as invented data.
    test "renders no obligations, summary cards, or calendar", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/compliance")

      refute html =~ "Compliance Tasks"
      refute html =~ "Upcoming Due Dates"
      refute html =~ "Compliance Calendar"
      refute html =~ "View Filing Calendar"
      refute html =~ "Total Returns"
      refute html =~ "GSTR-1"
      refute html =~ "GSTR-3B"
      refute html =~ "CMP-08"
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/compliance")
    end
  end
end
