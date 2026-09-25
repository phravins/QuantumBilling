defmodule QuantumBillingWeb.EWayBillDocumentTest do
  @moduledoc """
  The official e-way bill, end to end: the routes that serve it and what the
  page an officer reads actually says.

  Generating a bill used to write a number onto the invoice and nothing else —
  the list page's View and Print buttons both went to a filtered invoice list,
  so Form GST EWB-01 existed nowhere in the application.

  The document is now addressed by the **bill's** id rather than the invoice's,
  because an invoice may carry a cancelled bill and the one raised to replace
  it, and a URL meaning "the invoice's bill" could not name which.
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

    {:ok, bill} =
      EWayBills.generate_e_way_bill(invoice, %{
        "distance_km" => "310",
        "vehicle_number" => "MH12AB1234",
        "transporter_name" => "Express Logistics India"
      })

    bill
  end

  describe "the printable document" do
    test "serves Form GST EWB-01 for a generated bill", %{conn: conn} do
      bill = invoice_with_bill()

      body = conn |> get(~p"/e-way-bills/#{bill.id}/print") |> response(200)

      assert body =~ "Form GST EWB-01"
      assert body =~ "Part - A"
      assert body =~ "Part - B"
      # The number prints in the groups of four the portal uses.
      assert body =~ Document.grouped(bill.ewb_number)
      assert body =~ bill.invoice.invoice_number
      assert body =~ "MH12AB1234"
      assert body =~ "Express Logistics India"
      assert body =~ "310 km"
      # The goods table is the part an officer reads.
      assert body =~ "8471"
      assert body =~ "Wireless keyboard"
    end

    test "carries a QR of the bill, its issuer and its date", %{conn: conn} do
      bill = invoice_with_bill()

      assert Document.qr_payload(bill) ==
               Enum.join(
                 [
                   bill.ewb_number,
                   bill.invoice.company_gstin,
                   Calendar.strftime(bill.ewb_date, "%d/%m/%Y")
                 ],
                 "/"
               )

      body = conn |> get(~p"/e-way-bills/#{bill.id}/print") |> response(200)

      assert body =~ "<svg"
      assert body =~ "Scan to verify"
    end

    # The toolbar's Print button always calls window.print(); only `?print=1`
    # should fire it without being asked.
    test "prints on load only when asked", %{conn: conn} do
      bill = invoice_with_bill()

      refute conn |> get(~p"/e-way-bills/#{bill.id}/print") |> response(200) =~
               "window.addEventListener"

      assert conn |> get(~p"/e-way-bills/#{bill.id}/print?print=1") |> response(200) =~
               "window.addEventListener"
    end

    # An unregistered recipient is "URP" on an e-way bill, not a blank.
    test "marks an unregistered recipient URP", %{conn: conn} do
      bill = invoice_with_bill()
      {:ok, _invoice} = Invoices.update_invoice(bill.invoice, %{"client_gstin" => nil})

      assert conn |> get(~p"/e-way-bills/#{bill.id}/print") |> response(200) =~ "URP"
    end

    test "splits the tax rate the way the consignment is taxed", %{organization: organization} do
      intra = invoice_with_bill("Maharashtra (27)", "18")
      inter = invoice_with_bill("Karnataka (29)", "18")

      assert Document.html(intra, organization) =~ "9.00 + 9.00 + 0.00 + 0.00"
      assert Document.html(inter, organization) =~ "0.00 + 0.00 + 18.00 + 0.00"
    end

    # Part-B is a table of legs on the real form, so a vehicle change has to
    # add a row rather than quietly rewrite the one that is printed.
    test "prints every leg of the journey in Part-B", %{conn: conn} do
      bill = invoice_with_bill()

      {:ok, _updated} =
        EWayBills.update_part_b(bill, %{
          "vehicle_number" => "KA05CD9876",
          "mode_of_transport" => "Road",
          "place" => "Belgaum",
          "reason" => "Breakdown"
        })

      body = conn |> get(~p"/e-way-bills/#{bill.id}/print") |> response(200)

      # Both vehicles, the original one first.
      assert body =~ "MH12AB1234"
      assert body =~ "KA05CD9876"
      assert body =~ "Belgaum"

      [first, second] =
        Regex.scan(~r/MH12AB1234|KA05CD9876/, body)
        |> Enum.map(&hd/1)
        |> Enum.uniq()

      assert first == "MH12AB1234"
      assert second == "KA05CD9876"
    end

    # A cancelled bill still prints — it is the evidence that the consignment
    # did not travel under it.
    test "says so on the face of a cancelled bill", %{conn: conn} do
      bill = invoice_with_bill()

      {:ok, _cancelled} =
        EWayBills.cancel_e_way_bill(bill, %{"cancellation_reason" => "Order Cancelled"})

      body = conn |> get(~p"/e-way-bills/#{bill.id}/print") |> response(200)

      assert body =~ "cancelled"
      refute body =~ "valid until"
    end

    test "an id that is nobody's bill goes back to the list", %{conn: conn} do
      assert conn |> get(~p"/e-way-bills/999999/print") |> redirected_to() == ~p"/e-way-bills"
    end
  end

  describe "the PDF download" do
    test "either prints or says why it cannot", %{conn: conn} do
      bill = invoice_with_bill()

      conn = get(conn, ~p"/e-way-bills/#{bill.id}/print/download")

      case QuantumBillingWeb.InvoiceDoc.PDF.executable() do
        nil ->
          assert redirected_to(conn) == ~p"/e-way-bills/#{bill.id}/print"

        _binary ->
          assert <<"%PDF-", _rest::binary>> = response(conn, 200)
      end
    end
  end

  describe "the e-way bill list" do
    test "every row action opens the document", %{conn: conn} do
      bill = invoice_with_bill()

      {:ok, _view, html} = live(conn, ~p"/e-way-bills")

      assert html =~ ~s(href="/e-way-bills/#{bill.id}/print")
      assert html =~ ~s(href="/e-way-bills/#{bill.id}/print?print=1")
      assert html =~ ~s(href="/e-way-bills/#{bill.id}/print/download")
    end
  end
end
