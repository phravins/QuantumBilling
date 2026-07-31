defmodule QuantumBillingWeb.ClientsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  # Search, sorting, status filtering, pagination and the summary-tile filter
  # shortcuts all need rows to act on, and there are none until the clients
  # table exists. Those tests come back with the schema, built on database
  # fixtures rather than invented records.

  test "renders the page shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    assert html =~ "Clients"
  end

  test "keeps the toolbar available", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/clients")

    assert has_element?(view, "#clients-search")
    assert html =~ "All Status"
  end

  test "shows an empty state rather than a bare table", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    assert html =~ "No clients yet"
    assert html =~ "Customers you invoice will appear here."
    refute html =~ "entries"
  end

  test "the summary tiles read zero rather than dividing by zero", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    assert html =~ "0% of total"
  end

  test "distinguishes an empty account from an empty search", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    html = view |> form("#clients-search", %{"q" => "anything"}) |> render_change()

    assert html =~ "No clients match these filters"
  end

  test "serves no sample records", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    refute html =~ "V2V Technologies"
    refute html =~ "Insta Capital"
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/clients")
  end
end
