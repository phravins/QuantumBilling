defmodule QuantumBillingWeb.DashboardLiveTest do
  @moduledoc """
  The dashboard, now the only overview page: the Reports page it duplicated is
  gone, and its tax summary, top clients and export moved here.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  setup :register_and_log_in_user

  defp insert_invoice(attrs) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_number: "INV-#{System.unique_integer([:positive])}",
          invoice_date: Date.utc_today(),
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_name: "Acme Corp",
          taxable_value: 1_000_000,
          cgst_amount: 90_000,
          sgst_amount: 90_000,
          grand_total: 1_180_000,
          status: "Draft"
        },
        attrs
      )
    )
  end

  test "carries the tax summary, top clients, compliance and export", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#dashboard-tax-summary")
    assert has_element?(view, "#dashboard-top-clients")
    assert has_element?(view, "#dashboard-export")
    assert has_element?(view, ~s(#export-tax-summary[href^="/reports/export"]))
    assert has_element?(view, ~s(#export-sales-register[href*="Sales+Register"]))
    assert html =~ "Compliance Calendar"
    refute html =~ "Recent Tax Invoices"
  end

  test "shows empty states before anything is billed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert view |> element("#dashboard-tax-summary") |> render() =~ "No tax to summarise yet"
    assert view |> element("#dashboard-top-clients") |> render() =~ "No clients billed yet"
  end

  test "summarises this year's tax and ranks its clients", %{conn: conn} do
    insert_invoice(%{client_name: "Acme Corp"})
    insert_invoice(%{client_name: "Beta Ltd", taxable_value: 5_000_000})

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    tax = view |> element("#dashboard-tax-summary") |> render()
    assert tax =~ "CGST + SGST"
    assert tax =~ "Total"

    clients = view |> element("#dashboard-top-clients") |> render()
    assert clients =~ "Beta Ltd"
    assert clients =~ "Acme Corp"
    # Highest value first.
    assert :binary.match(clients, "Beta Ltd") < :binary.match(clients, "Acme Corp")
  end

  test "the Reports page is gone from the sidebar and the router", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/dashboard")

    refute html =~ ~s(href="/reports")
    assert conn |> get("/reports") |> response(404)
  end
end
