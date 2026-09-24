defmodule QuantumBillingWeb.EWayBillNewLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  setup :register_and_log_in_user

  defp invoice_fixture(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_number: "INV-2024-0001",
          invoice_date: ~D[2024-05-28],
          invoice_type: "Tax Invoice",
          place_of_supply: "Maharashtra (27)",
          company_name: "ABC Solutions Private Limited",
          company_gstin: "27AABCA1234A1Z5",
          company_state: "Maharashtra (27)",
          client_name: "V2V Technologies",
          client_state: "Maharashtra (27)",
          client_city: "Pune",
          taxable_value: 60_000,
          cgst_amount: 5_400,
          sgst_amount: 5_400,
          grand_total: 70_800
        },
        attrs
      )
    )
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "supply_type" => "Outward Supply",
        "sub_type" => "Supply",
        "document_type" => "Tax Invoice",
        "document_no" => "INV-2024-0001",
        "document_date" => "2024-05-28",
        "transaction_type" => "Regular",
        "from_party" => "ABC Solutions Private Limited",
        "from_state" => "Maharashtra (27)",
        "to_party" => "V2V Technologies",
        "to_state" => "Maharashtra (27)",
        "total_goods_value" => "60000",
        "cgst_value" => "5400",
        "sgst_value" => "5400",
        "igst_value" => "0",
        "other_amount" => "0",
        "transport_mode" => "Road",
        "transporter_name" => "ABC Transport Services",
        "vehicle_no" => "MH01AB1234",
        "from_place" => "Mumbai",
        "to_place" => "Pune",
        "distance_km" => "150"
      },
      overrides
    )
  end

  test "renders all five sections and the summary panel", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills/new")

    assert html =~ "Generate New E-Way Bill"
    assert html =~ "Transaction Details"
    assert html =~ "Parties Details"
    assert html =~ "Item Details"
    assert html =~ "Transport Details"
    assert html =~ "Other Details (Optional)"
    assert html =~ "E-Way Bill Summary"
    # breadcrumb back to the list
    assert html =~ ~s(href="/e-way-bills")
  end

  test "seeds the common defaults", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills/new")

    # LiveView emits the attributes in this order: `<option selected="" value="…">`.
    assert html =~ ~s(<option selected="" value="Outward Supply">)
    assert html =~ ~s(<option selected="" value="Tax Invoice">)
    assert html =~ ~s(<option selected="" value="Road">)
  end

  test "recomputes the total invoice value as amounts change", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/e-way-bills/new")

    assert html =~ "₹ 0.00"

    updated =
      view
      |> form("#ewb-form",
        e_way_bill: %{
          "total_goods_value" => "60000",
          "cgst_value" => "5400",
          "sgst_value" => "5400"
        }
      )
      |> render_change()

    assert updated =~ "₹ 70,800.00"
  end

  test "mirrors the entered parties into the summary panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills/new")

    html =
      view
      |> form("#ewb-form",
        e_way_bill: %{"to_party" => "Nimbus Logistics", "from_place" => "Nagpur"}
      )
      |> render_change()

    assert html =~ "Nimbus Logistics"
    assert html =~ "Nagpur"
  end

  test "submitting an empty form shows errors and stays on the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills/new")

    html =
      view
      |> form("#ewb-form", e_way_bill: %{"document_no" => "", "vehicle_no" => ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert html =~ "Please fix the highlighted fields"
    # still on the form
    assert html =~ "E-Way Bill Summary"
  end

  test "rejects a malformed vehicle number", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills/new")

    html =
      view
      |> form("#ewb-form", e_way_bill: valid_attrs(%{"vehicle_no" => "XX-1"}))
      |> render_submit()

    assert html =~ "must look like MH01AB1234"
  end

  # The page used to mint a random number into a flash and navigate away
  # without storing anything: the bill it announced existed nowhere, least of
  # all on the list it returned to.
  test "a complete submission issues a real bill against the invoice", %{conn: conn} do
    invoice = invoice_fixture()

    {:ok, view, _html} = live(conn, ~p"/e-way-bills/new")

    assert {:error, {:redirect, %{to: to}}} =
             view |> form("#ewb-form", e_way_bill: valid_attrs()) |> render_submit()

    issued = Invoices.get_invoice_by_number(invoice.invoice_number)

    assert to == "/e-way-bills/#{issued.id}/print"
    assert issued.ewb_number =~ ~r/^\d{12}$/
    assert issued.distance_km == 150
    assert issued.vehicle_number == "MH01AB1234"
    # One day per 200 km, so 150 km expires at the end of tomorrow.
    assert NaiveDateTime.to_date(issued.ewb_valid_until) == Date.add(Date.utc_today(), 1)
  end

  test "a document number no invoice carries is a form error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills/new")

    html =
      view
      |> form("#ewb-form", e_way_bill: valid_attrs(%{"document_no" => "INV-NOPE-9"}))
      |> render_submit()

    assert html =~ "no invoice with this number"
    assert html =~ "E-Way Bill Summary"
  end

  test "an invoice that already carries a bill is refused", %{conn: conn} do
    invoice_fixture(%{ewb_number: "191011112222", ewb_date: ~D[2024-05-29]})

    {:ok, view, _html} = live(conn, ~p"/e-way-bills/new")

    html = view |> form("#ewb-form", e_way_bill: valid_attrs()) |> render_submit()

    assert html =~ "already has an e-way bill"
  end

  test "loading an invoice fills the consignment in", %{conn: conn} do
    invoice = invoice_fixture(%{client_name: "Nimbus Logistics"})

    {:ok, view, html} = live(conn, ~p"/e-way-bills/new")

    assert html =~ invoice.invoice_number

    filled =
      view
      |> form("#ewb-load-invoice", %{"invoice_id" => to_string(invoice.id)})
      |> render_change()

    assert filled =~ "Nimbus Logistics"
    assert filled =~ ~s(value="INV-2024-0001")
  end

  test "counts remark characters", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/e-way-bills/new")

    assert html =~ "0 / 500"

    updated =
      view
      |> form("#ewb-form", e_way_bill: %{"remarks" => "Handle with care"})
      |> render_change()

    assert updated =~ "16 / 500"
  end
end
