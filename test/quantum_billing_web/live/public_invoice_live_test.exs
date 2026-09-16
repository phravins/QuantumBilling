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

  test "the customer's document download does not require a login", %{conn: conn} do
    invoice =
      Repo.insert!(%Invoice{
        invoice_number: "INV-9911",
        invoice_date: ~D[2026-03-01],
        place_of_supply: "Maharashtra",
        company_state: "Maharashtra",
        client_name: "Zeta Logistics",
        public_token: "inv_public_download_9911",
        taxable_value: 10_000,
        cgst_amount: 900,
        sgst_amount: 900,
        grand_total: 11_800
      })

    # The page used to link at `/invoices/:id/pdf`, which lives behind
    # authentication — so a customer clicking "Download PDF" landed on a login
    # screen for an application they have no account on.
    conn = get(conn, ~p"/pay/#{invoice.public_token}/pdf")

    assert conn.status == 200
    refute redirected_to?(conn)

    case QuantumBillingWeb.InvoiceDoc.PDF.executable() do
      nil ->
        # Falls back to the print-styled page the customer's browser can save.
        assert response_content_type(conn, :html)
        assert response(conn, 200) =~ "INV-9911"

      _binary ->
        assert [disposition] = get_resp_header(conn, "content-disposition")
        assert disposition =~ "INV-9911.pdf"
        assert <<"%PDF-", _rest::binary>> = response(conn, 200)
    end
  end

  test "an unknown token is a 404 rather than an invoice", %{conn: conn} do
    conn = get(conn, ~p"/pay/inv_not_a_real_token/pdf")

    assert conn.status == 404
  end

  defp redirected_to?(conn), do: conn.status in 300..399

  test "redirects on invalid public token", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/pay/tok_invalid_does_not_exist")
  end
end
