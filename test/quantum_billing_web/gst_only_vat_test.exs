defmodule QuantumBillingWeb.GSTOnlyVATTest do
  @moduledoc """
  A VAT business neither sees nor reaches the India GST features: IRP
  e-invoice, e-way bills, GSTR-1, the HSN finder and the GST filing calendar.
  A GST business keeps them all.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.ApiFixtures

  alias QuantumBilling.Compliance
  alias QuantumBilling.Compliance.GSTNExporter
  alias QuantumBilling.EInvoice
  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Tax

  @gst_pages ["/e-way-bills", "/e-way-bills/new", "/hsn-finder"]
  @gst_links ["/e-way-bills", "/hsn-finder"]
  @uae %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => "100123456700003"}

  setup :register_and_log_in_owner

  defp use_vat(_context) do
    {:ok, _organization} = Settings.update_section(Settings.get_organization(), @uae, :tax)
    :ok
  end

  defp sidebar_link?(view, path), do: has_element?(view, "nav a[href='#{path}']")

  describe "a GST business" do
    test "keeps the GST tools", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      for path <- @gst_links, do: assert(sidebar_link?(view, path), path)
      assert has_element?(view, "#settings-link-e_way_bill")

      invoice = invoice_fixture()
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")
      assert has_element?(view, "#drawer-gst-tools")

      for path <- @gst_pages, do: assert({:ok, _view, _html} = live(conn, path))
    end

    test "still tracks the GST returns once a GSTIN is saved" do
      registration = %{Settings.get_organization() | gstin: "27AAAAA0000A1Z5"}

      obligations = Compliance.tracked_obligations(~D[2026-11-11], registration)
      assert Enum.any?(obligations, &(&1.type == "GSTR-1"))
    end
  end

  describe "a VAT business" do
    setup :use_vat

    test "has no GST tools in the sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      for path <- @gst_links, do: refute(sidebar_link?(view, path), path)
      assert sidebar_link?(view, "/compliance")
      refute has_element?(view, "#settings-link-e_way_bill")
      assert has_element?(view, "#settings-link-tax")
    end

    test "is sent from the GST pages to the dashboard with the reason", %{conn: conn} do
      for path <- @gst_pages do
        assert {:error, {:redirect, %{to: "/dashboard", flash: %{"error" => message}}}} =
                 live(conn, path)

        assert message =~ "India GST", path
      end
    end

    test "cannot open the e-way bill settings", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/settings/general", flash: flash}}} =
               live(conn, ~p"/settings/e_way_bill")

      assert flash["error"] == Tax.gst_only_message(:e_way_bills)
    end

    test "cannot export e-way bills or GSTR-1", %{conn: conn} do
      conn_ewb = get(conn, ~p"/e-way-bills/export")
      assert redirected_to(conn_ewb) == ~p"/dashboard"
      assert Phoenix.Flash.get(conn_ewb.assigns.flash, :error) =~ "E-way bills"

      conn_gstr = get(conn, ~p"/reports/gstr1/export?#{[period: "102026"]}")
      assert redirected_to(conn_gstr) == ~p"/compliance"
      assert Phoenix.Flash.get(conn_gstr.assigns.flash, :error) == Tax.gst_only_message(:gstr1)

      assert {:error, message} = GSTNExporter.generate_gstr1_json("102026")
      assert message =~ "GSTR-1"
    end

    test "tracks no GST returns, even with a GSTIN left over" do
      registration = %{Settings.get_organization() | gstin: "27AAAAA0000A1Z5"}

      assert Compliance.tracked_obligations(~D[2026-11-11], registration) == []
    end

    test "the compliance page keeps its own tasks and drops the GST wording", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      assert has_element?(view, "#vat-compliance-empty")
      refute render(view) =~ "No GST registration on file"
    end

    test "a VAT invoice offers no IRN or e-way bill", %{conn: conn} do
      invoice = invoice_fixture(%{tax_regime: "vat", place_of_supply: nil})

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")
      refute has_element?(view, "#drawer-gst-tools")

      # Forged events are refused too, and leave the invoice as it was.
      assert render_click(view, "generate_einvoice", %{}) =~
               "IRP e-invoicing is part of India GST"

      assert render_click(view, "generate_ewb", %{"distance_km" => "10"}) =~
               "E-way bills are part of India GST"

      assert Repo.get!(Invoice, invoice.id).status == invoice.status
      assert EWayBills.live_bill_for_invoice(invoice.id) == nil
    end

    test "an invoice raised before the switch is refused as well" do
      invoice = invoice_fixture()

      assert Tax.ensure_gst(invoice) == {:error, :gst_only}
      assert Invoices.queue_einvoice(invoice) == {:error, :gst_only}

      assert EWayBills.generate_e_way_bill(invoice, %{"distance_km" => "10"}) ==
               {:error, :gst_only}

      assert {:error, [message]} = EInvoice.validate(invoice, Settings.get_organization())
      assert message == Tax.gst_only_message(:e_invoice)
      assert Repo.get!(Invoice, invoice.id).status == invoice.status
    end

    test "the e-invoice XML is refused with the reason", %{conn: conn} do
      invoice = invoice_fixture(%{tax_regime: "vat", place_of_supply: nil})

      conn = get(conn, ~p"/invoices/#{invoice.id}/e-invoice.xml")

      assert redirected_to(conn) == ~p"/invoices/#{invoice.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "India GST"
    end

    test "the API refuses IRN registration with 409 gst_only", %{user: owner} do
      {raw, _key} = api_key_fixture(["invoices:e_invoice"], %{owner: owner})
      invoice = invoice_fixture(%{tax_regime: "vat", place_of_supply: nil})

      conn = raw |> api_conn() |> api_post(~p"/api/v1/invoices/#{invoice.id}/e-invoice", %{})

      assert %{"error" => %{"code" => "gst_only", "message" => message}} =
               json_response(conn, 409)

      assert message =~ "India GST"
      assert Repo.get!(Invoice, invoice.id).status == invoice.status
    end
  end

  test "switching to VAT in Settings drops the GST links at once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/tax")
    assert sidebar_link?(view, "/e-way-bills")

    view
    |> form("#settings-form", %{"organization" => %{"tax_regime" => "vat"}})
    |> render_change()

    view |> form("#settings-form", %{"organization" => @uae}) |> render_submit()

    refute sidebar_link?(view, "/e-way-bills")
    refute sidebar_link?(view, "/hsn-finder")
    refute has_element?(view, "#settings-link-e_way_bill")
  end
end
