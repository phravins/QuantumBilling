defmodule QuantumBillingWeb.EWayBillsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  # Search, sorting, status filtering and pagination need rows to act on, and
  # there are none until the e-way bills table exists. Those tests come back
  # with the schema, built on database fixtures rather than invented records.

  test "renders the page shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ "Track consignments and generate new e-way bills"
  end

  test "links to the generate form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ ~s(href="/e-way-bills/new")
    assert html =~ "Generate New E-Way Bill"
  end

  test "shows an empty state rather than a bare table", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ "No e-way bills yet"
    refute html =~ "entries"
  end

  test "distinguishes an empty account from an empty search", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    html = view |> form("#ewb-search", %{"q" => "anything"}) |> render_change()

    assert html =~ "No e-way bills match these filters"
  end

  test "serves no sample records", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    refute html =~ "V2V Technologies"
    refute html =~ "INV-2024-"
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/e-way-bills")
  end
end
