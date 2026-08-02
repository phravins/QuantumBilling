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

  test "the Add New Client button links to the form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    assert html =~ ~s(href="/clients/new")
  end

  describe "with clients in the database" do
    setup do
      {:ok, registered} =
        QuantumBilling.Clients.create_client(%{
          "client_type" => "Registered Business",
          "name" => "Acme Traders",
          "gstin" => "27AABCA1234A1Z5",
          "email" => "billing@acme.in",
          "phone" => "9876543210",
          "billing_line1" => "123 Business Park",
          "billing_city" => "Mumbai",
          "billing_state" => "Maharashtra (27)",
          "billing_pin" => "400093"
        })

      # No GSTIN and no email — the shape that used to crash the search.
      {:ok, walk_in} =
        QuantumBilling.Clients.create_client(%{
          "client_type" => "Consumer",
          "name" => "Walk-in Buyer",
          "phone" => "9000000000",
          "billing_line1" => "Shop 2",
          "billing_city" => "Pune",
          "billing_state" => "Maharashtra (27)",
          "billing_pin" => "411001"
        })

      # Not :registered — ExUnit reserves that context key.
      %{business_client: registered, walk_in: walk_in}
    end

    test "a saved client appears in the table", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/clients")

      assert html =~ "Acme Traders"
      assert html =~ "27AABCA1234A1Z5"
      assert html =~ "billing@acme.in"
      assert html =~ "Walk-in Buyer"
      refute html =~ "No clients yet"
    end

    test "search finds a client by name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = view |> form("#clients-search", %{"q" => "Acme"}) |> render_change()

      assert html =~ "Acme Traders"
      refute html =~ "Walk-in Buyer"
    end

    test "search does not crash on a client with no GSTIN or email", %{conn: conn} do
      # filter_search/2 used to call String.downcase/1 on both unguarded, so any
      # search at all blew up once an unregistered client existed.
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = view |> form("#clients-search", %{"q" => "walk"}) |> render_change()

      assert html =~ "Walk-in Buyer"
      refute html =~ "Acme Traders"
    end

    test "search by GSTIN still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = view |> form("#clients-search", %{"q" => "27AABCA"}) |> render_change()

      assert html =~ "Acme Traders"
      refute html =~ "Walk-in Buyer"
    end

    test "sorting by name works over real rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = render_click(view, "sort", %{"field" => "name"})

      assert html =~ "Acme Traders"
      assert html =~ "Walk-in Buyer"
    end
  end
end
