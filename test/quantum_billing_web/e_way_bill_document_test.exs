defmodule QuantumBillingWeb.EWayBillDocumentTest do
  @moduledoc """
  The official e-way bill, end to end: the routes that serve it and what the
  page an officer reads actually says.

  Generating a bill used to write a number onto the invoice and nothing else —
  the list page's View and Print buttons both went to a filtered invoice list,
  so Form GST EWB-01 existed nowhere in the application.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBillingWeb.EWayBillDoc.Document

  setup :register_and_log_in_user

  setup do
    {:ok, organization} =
      Settings.update_section(
        Settings.ensure_organization(),
        %{
          "company_name" => "Acme Traders Private Limited",
          "address" => "221B Example Street",
          "city" => "Mumbai",
          "pincode" => "400001",
          "gstin" => "27AABCA1234A1Z5",
          "pan" => "AABCA1234A",
          "state" => "Maharashtra (27)"
        },
        :general
      )

    %{organization: organization}
  end

  defp invoice_with_bill(place_of_supply \\ "Maharashtra (27)", tax_rate \\ "18") do
    {:ok, invoice} =
      Invoices.create_invoice(%{
        "invoice_date" => Date.to_iso8601(~D[2026-04-18]),
        "place_of_supply" => place_of_supply,
        "client_name" => "Northwind Traders",
        "client_billing_address" => "14 Harbour Road",
        "client_city" => "Nagpur",
        "client_state" => place_of_supply,
        "client_pincode" => "440001",
        "client_gstin" => "27AAACP8542D1ZS",
        "items" => %{
          "0" => %{
            "description" => "Wireless keyboard",
            "hsn_sac" => "8471",
            "quantity" => "4",
            "unit" => "Nos",
            "rate" => "2500",
            "tax_rate" => tax_rate
          }
        }
      })

    {:ok, issued} =
      EWayBills.generate_e_way_bill(invoice, %{
        "distance_km" => "310",
        "vehicle_number" => "MH12AB1234",
        "transporter_name" => "Express Logistics India"
      })

    issued
  end

  describe "the printable document" do
    test "serves Form GST EWB-01 for a generated bill", %{conn: conn} do
      invoice = invoice_with_bill()

      body = conn |> get(~p"/e-way-bills/#{invoice.id}/print") |> response(200)

      assert body =~ "Form GST EWB-01"
      assert body =~ "Part - A"
      assert body =~ "Part - B"
      # The number prints in the groups of four the portal uses.
      assert body =~ Document.grouped(invoice.ewb_number)
      assert body =~ invoice.invoice_number
      assert body =~ "MH12AB1234"
      assert body =~ "Express Logistics India"
      assert body =~ "310 km"
      # The goods table is the part an officer reads.
      assert body =~ "8471"
      assert body =~ "Wireless keyboard"
    end

    test "carries a QR of the bill, its issuer and its date", %{conn: conn} do
      invoice = invoice_with_bill()

      assert Document.qr_payload(invoice) ==
               Enum.join(
                 [
                   invoice.ewb_number,
                   invoice.company_gstin,
                   Calendar.strftime(invoice.ewb_date, "%d/%m/%Y")
                 ],
                 "/"
               )

      body = conn |> get(~p"/e-way-bills/#{invoice.id}/print") |> response(200)

      assert body =~ "<svg"
      assert body =~ "Scan to verify"
    end

    # The toolbar's Print button always calls window.print(); only `?print=1`
    # should fire it without being asked.
    test "prints on load only when asked", %{conn: conn} do
      invoice = invoice_with_bill()

      refute conn |> get(~p"/e-way-bills/#{invoice.id}/print") |> response(200) =~
               "window.addEventListener"

      assert conn |> get(~p"/e-way-bills/#{invoice.id}/print?print=1") |> response(200) =~
               "window.addEventListener"
    end

    # An unregistered recipient is "URP" on an e-way bill, not a blank.
    test "marks an unregistered recipient URP", %{conn: conn} do
      invoice = invoice_with_bill()
      {:ok, invoice} = Invoices.update_invoice(invoice, %{"client_gstin" => nil})

      assert conn |> get(~p"/e-way-bills/#{invoice.id}/print") |> response(200) =~ "URP"
    end

    test "splits the tax rate the way the consignment is taxed", %{organization: _organization} do
      intra = invoice_with_bill("Maharashtra (27)", "18")
      inter = invoice_with_bill("Karnataka (29)", "18")

      assert Document.html(intra, Settings.get_organization()) =~ "9.00 + 9.00 + 0.00 + 0.00"
      assert Document.html(inter, Settings.get_organization()) =~ "0.00 + 0.00 + 18.00 + 0.00"
    end

    test "an invoice with no bill has no document to print", %{conn: conn} do
      {:ok, invoice} =
        Invoices.create_invoice(%{
          "invoice_date" => Date.to_iso8601(~D[2026-04-18]),
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "Northwind Traders",
          "items" => %{
            "0" => %{"description" => "Consulting", "quantity" => "1", "rate" => "1000"}
          }
        })

      conn = get(conn, ~p"/e-way-bills/#{invoice.id}/print")

      assert redirected_to(conn) == ~p"/invoices/#{invoice.id}"
    end

    test "an id that is nobody's invoice goes back to the list", %{conn: conn} do
      assert conn |> get(~p"/e-way-bills/999999/print") |> redirected_to() == ~p"/e-way-bills"
    end
  end

  describe "the PDF download" do
    test "either prints or says why it cannot", %{conn: conn} do
      invoice = invoice_with_bill()

      conn = get(conn, ~p"/e-way-bills/#{invoice.id}/print/download")

      case QuantumBillingWeb.InvoiceDoc.PDF.executable() do
        nil ->
          assert redirected_to(conn) == ~p"/e-way-bills/#{invoice.id}/print"

        _binary ->
          assert <<"%PDF-", _rest::binary>> = response(conn, 200)
      end
    end
  end

  describe "the e-way bill list" do
    test "every row action opens the document", %{conn: conn} do
      invoice = invoice_with_bill()

      {:ok, _view, html} = live(conn, ~p"/e-way-bills")

      assert html =~ ~s(href="/e-way-bills/#{invoice.id}/print")
      assert html =~ ~s(href="/e-way-bills/#{invoice.id}/print?print=1")
      assert html =~ ~s(href="/e-way-bills/#{invoice.id}/print/download")
    end
  end
end
