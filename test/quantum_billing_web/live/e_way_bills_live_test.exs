defmodule QuantumBillingWeb.EWayBillsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  setup :register_and_log_in_user

  defp bill(attrs) do
    defaults = %{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_state: "Karnataka",
      client_name: "Acme India Pvt Ltd",
      taxable_value: 100_000,
      grand_total: 118_000,
      ewb_number: "191000#{System.unique_integer([:positive])}",
      ewb_date: ~D[2026-03-01],
      ewb_valid_until: ~N[2036-03-05 00:00:00],
      distance_km: 180,
      vehicle_number: "MH04CD5678"
    }

    Repo.insert!(struct(%Invoice{}, Map.merge(defaults, attrs)))
  end

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

  test "renders a real bill", %{conn: conn} do
    # This is the regression this page most needed: every column was written
    # against field names no schema has — `ewb_no`, `to_party`, `value` — so
    # rendering a single genuine e-way bill raised a KeyError and the page was
    # reachable only while it had nothing to show.
    bill = bill(%{client_name: "Northwind Traders", ewb_number: "191000111222"})

    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ "191000111222"
    assert html =~ "Northwind Traders"
    assert html =~ bill.invoice_number
    assert html =~ "Maharashtra"
    assert html =~ "Karnataka"
    refute html =~ "No e-way bills"
  end

  test "searches on the EWB number, the document number and the consignee", %{conn: conn} do
    bill(%{client_name: "Northwind Traders", ewb_number: "191000111222"})
    bill(%{client_name: "Contoso Logistics", ewb_number: "191000333444"})

    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    html = view |> form("#ewb-search", %{"q" => "Northwind"}) |> render_change()
    assert html =~ "Northwind Traders"
    refute html =~ "Contoso Logistics"

    html = view |> form("#ewb-search", %{"q" => "333444"}) |> render_change()
    assert html =~ "Contoso Logistics"
    refute html =~ "Northwind Traders"
  end

  test "filters by a status derived from validity and cancellation", %{conn: conn} do
    bill(%{client_name: "Still Valid Ltd"})
    bill(%{client_name: "Long Gone Ltd", ewb_valid_until: ~N[2020-01-01 00:00:00]})
    bill(%{client_name: "Called Off Ltd", status: "Cancelled"})

    {:ok, view, html} = live(conn, ~p"/e-way-bills")
    assert html =~ "Still Valid Ltd"
    assert html =~ "Long Gone Ltd"

    html = render_click(view, "filter_status", %{"status" => "Expired"})
    assert html =~ "Long Gone Ltd"
    refute html =~ "Still Valid Ltd"

    html = render_click(view, "filter_status", %{"status" => "Active"})
    assert html =~ "Still Valid Ltd"
    refute html =~ "Long Gone Ltd"
    refute html =~ "Called Off Ltd"

    html = render_click(view, "filter_status", %{"status" => "Cancelled"})
    assert html =~ "Called Off Ltd"
    refute html =~ "Still Valid Ltd"
  end

  test "pages rather than listing everything", %{conn: conn} do
    for index <- 1..12 do
      bill(%{client_name: "Consignee #{String.pad_leading(to_string(index), 2, "0")}"})
    end

    {:ok, view, html} = live(conn, ~p"/e-way-bills")

    # Ten rows to a page, so the twelve above need two. Newest first, and the
    # id breaks the tie between bills issued on the same day, so the last two
    # created are the ones that fall onto page two.
    assert html =~ "Consignee 12"
    refute html =~ "Consignee 01"

    html = render_click(view, "paginate", %{"page" => "2"})
    assert html =~ "Consignee 01"
    assert html =~ "Consignee 02"
    refute html =~ "Consignee 12"
  end

  test "survives a sort on a column it does not sort by", %{conn: conn} do
    bill(%{client_name: "Northwind Traders"})

    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    # A stale link or a hand-edited event used to reach
    # `String.to_existing_atom/1` and take the page down with it.
    assert render_click(view, "sort", %{"field" => "not_a_column"}) =~ "Northwind Traders"
    assert render_click(view, "sort", %{"field" => "value"}) =~ "Northwind Traders"
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
