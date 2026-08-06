defmodule QuantumBillingWeb.EInvoiceControllerTest do
  use QuantumBillingWeb.ConnCase, async: true

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings

  setup :register_and_log_in_user

  setup do
    {:ok, _organization} =
      Settings.update_section(
        Settings.ensure_organization(),
        %{
          "company_name" => "Acme Traders Private Limited",
          "address" => "221B Example Street",
          "city" => "Mumbai",
          "pincode" => "400001",
          "gstin" => "27AABCA1234A1Z5",
          "state" => "Maharashtra (27)"
        },
        :general
      )

    :ok
  end

  defp invoice(item_attrs \\ %{}) do
    {:ok, invoice} =
      Invoices.create_invoice(%{
        "invoice_date" => Date.to_iso8601(~D[2026-04-18]),
        "place_of_supply" => "Maharashtra (27)",
        "client_name" => "Northwind Traders",
        "client_billing_address" => "14 Harbour Road",
        "client_city" => "Mumbai",
        "client_pincode" => "400002",
        "items" => %{
          "0" =>
            Map.merge(
              %{
                "description" => "Design retainer",
                "hsn_sac" => "998311",
                "quantity" => "2",
                "rate" => "500"
              },
              item_attrs
            )
        }
      })

    invoice
  end

  describe "GET /invoices/:id/e-invoice.xml" do
    test "downloads the XML as an attachment", %{conn: conn} do
      invoice = invoice()

      conn = get(conn, ~p"/invoices/#{invoice.id}/e-invoice.xml")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "einvoice-#{invoice.invoice_number}.xml"
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/xml"
    end

    test "the body parses as XML", %{conn: conn} do
      body = conn |> get(~p"/invoices/#{invoice().id}/e-invoice.xml") |> response(200)

      assert {:ok, {"Invoice", _attrs, _children}} = Saxy.SimpleForm.parse_string(body)
    end

    # Refusing is the point: a silently wrong tax document is worse than none,
    # and the flash names what to fix.
    test "an invoice that cannot be reported redirects with the reasons", %{conn: conn} do
      invoice = invoice(%{"hsn_sac" => nil})

      conn = get(conn, ~p"/invoices/#{invoice.id}/e-invoice.xml")

      assert redirected_to(conn) == ~p"/invoices/#{invoice.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "HSN"
    end

    test "an unknown invoice redirects to the list", %{conn: conn} do
      conn = get(conn, ~p"/invoices/0/e-invoice.xml")

      assert redirected_to(conn) == ~p"/invoices"
    end

    test "requires authentication" do
      assert build_conn()
             |> get(~p"/invoices/1/e-invoice.xml")
             |> redirected_to() == ~p"/users/log-in"
    end
  end
end
