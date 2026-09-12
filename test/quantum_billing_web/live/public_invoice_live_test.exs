defmodule QuantumBillingWeb.PublicInvoiceLiveTest do
  use QuantumBillingWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  test "renders public invoice portal using valid token", %{conn: conn} do
    invoice = %Invoice{
      id: 501,
      invoice_number: "INV-9910",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_name: "Zeta Logistics",
      public_token: "tok_test_public_9910",
      grand_total: 75000,
      status: "Draft"
    }

    invoice = Repo.insert!(invoice)

    {:ok, view, html} = live(conn, ~p"/pay/#{invoice.public_token}")
    assert html =~ "INV-9910"
    assert html =~ "Zeta Logistics"
    assert html =~ "Pay Now via UPI / Card"

    # Clicking pay_now triggers redirect or payment link creation
    assert render_click(view, "pay_now")
  end

  test "redirects on invalid public token", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/pay/tok_invalid_does_not_exist")
  end
end
