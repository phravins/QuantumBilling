defmodule QuantumBillingWeb.InvoiceShowLiveTest do
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings

  setup :register_and_log_in_user

  defp create_invoice(over \\ %{}) do
    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{
          "company_name" => "ABC Solutions Private Limited",
          "gstin" => "27AABCA1234A1Z5",
          "state" => "Maharashtra (27)",
          "address" => "123 Business Park\nAndheri East, Mumbai"
        },
        :general
      )

    attrs =
      Map.merge(
        %{
          "invoice_date" => "2024-05-28",
          "due_date" => "2024-06-12",
          "payment_terms" => "Net 15 Days",
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "V2V Technologies",
          "client_gstin" => "27AAACP8542D1ZS",
          "client_email" => "billing@v2v.in",
          "client_billing_address" => "123 Business Park\nMumbai",
          "remarks" => "Thanks for your business",
          "terms" => "Payment due within 15 days",
          "items" => %{
            "0" => %{
              "description" => "Web Development Services",
              "hsn_sac" => "998313",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "50000",
              "tax_rate" => "18",
              "position" => "0"
            },
            "1" => %{
              "description" => "Hosting Services",
              "hsn_sac" => "998422",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "10000",
              "tax_rate" => "18",
              "position" => "1"
            }
          }
        },
        over
      )

    {:ok, invoice} = Invoices.create_invoice(attrs)
    invoice
  end

  describe "the document" do
    test "renders the invoice's real figures", %{conn: conn} do
      invoice = create_invoice()

      {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert html =~ invoice.invoice_number
      assert html =~ "Tax Invoice"
      assert html =~ "₹ 60,000.00"
      assert html =~ "₹ 5,400.00"
      assert html =~ "₹ 70,800.00"
      assert html =~ "Rupees Seventy Thousand Eight Hundred Only"
    end

    test "shows both parties from the snapshot", %{conn: conn} do
      invoice = create_invoice()

      {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert html =~ "ABC Solutions Private Limited"
      assert html =~ "27AABCA1234A1Z5"
      assert html =~ "V2V Technologies"
      assert html =~ "27AAACP8542D1ZS"
    end

    test "lists every line item", %{conn: conn} do
      invoice = create_invoice()

      {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert html =~ "Web Development Services"
      assert html =~ "998313"
      assert html =~ "Hosting Services"
      assert html =~ "998422"
    end

    test "shows a Draft badge", %{conn: conn} do
      invoice = create_invoice()

      {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert html =~ "Draft"
    end

    test "shows remarks and terms when present", %{conn: conn} do
      invoice = create_invoice()

      {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert html =~ "Thanks for your business"
      assert html =~ "Payment due within 15 days"
    end

    test "links back to the list", %{conn: conn} do
      invoice = create_invoice()

      {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert html =~ "Back to Invoices"
      assert html =~ ~s(href="/invoices")
    end
  end

  describe "tax presentation" do
    test "an intra-state invoice shows CGST and SGST, not IGST", %{conn: conn} do
      invoice = create_invoice()

      {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert html =~ "CGST"
      assert html =~ "SGST"
      refute html =~ ">IGST<"
    end

    test "an inter-state invoice shows IGST instead", %{conn: conn} do
      invoice = create_invoice(%{"place_of_supply" => "Karnataka (29)"})

      {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert html =~ "IGST"
      assert html =~ "₹ 10,800.00"
      refute html =~ ">CGST<"
    end
  end

  describe "access" do
    test "requires authentication" do
      invoice = create_invoice()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/invoices/#{invoice.id}")
    end

    test "an invoice that does not exist redirects rather than crashing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/invoices"}}} = live(conn, ~p"/invoices/999999")
    end

    test "a nonsense id redirects rather than crashing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/invoices"}}} = live(conn, ~p"/invoices/not-an-id")
    end
  end
end
