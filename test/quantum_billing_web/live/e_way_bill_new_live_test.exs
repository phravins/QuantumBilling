defmodule QuantumBillingWeb.EWayBillNewLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

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
        "to_place" => "Pune"
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

    assert html =~ ~s(value="Outward Supply" selected)
    assert html =~ ~s(value="Tax Invoice" selected)
    assert html =~ ~s(value="Road" selected)
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

  test "a complete submission generates a number and returns to the list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills/new")

    result = view |> form("#ewb-form", e_way_bill: valid_attrs()) |> render_submit()

    assert {:ok, _view, html} = follow_redirect(result, conn, ~p"/e-way-bills")
    assert html =~ "generated successfully"
    assert html =~ ~r/E-Way Bill \d{12} generated successfully/
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
