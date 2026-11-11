defmodule QuantumBillingWeb.RecordCustomFieldsLiveTest do
  @moduledoc "Custom fields on credit notes, e-way bills and recurring profiles."
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.ApiFixtures, only: [client_fixture: 0]
  import QuantumBilling.CustomFieldsFixtures

  alias QuantumBilling.CreditNotes
  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Recurring
  alias QuantumBilling.Repo

  setup :register_and_log_in_user

  defp invoice(attrs \\ %{}) do
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
          grand_total: 70_800,
          public_token: "tok_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        },
        attrs
      )
    )
  end

  test "the credit-note modal saves its fields", %{conn: conn} do
    field_fixture("credit_note", %{"label" => "Return ref", "type" => "text"})
    invoice = invoice(%{client_id: client_fixture().id})

    {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")
    render_click(view, "toggle_cn_modal", %{})

    assert has_element?(
             view,
             ~s(#credit-note-form [name="credit_note[custom_fields][return_ref]"])
           )

    view
    |> form("#credit-note-form", %{
      "note_type" => "Credit",
      "reason" => "Goods returned",
      "grand_total" => "100",
      "credit_note" => %{"custom_fields" => %{"return_ref" => "RMA-9"}}
    })
    |> render_submit()

    assert [note] = CreditNotes.list_credit_notes()
    assert CreditNotes.get_credit_note!(note.id).custom_fields == %{"return_ref" => "RMA-9"}
  end

  test "the e-way bill form saves its fields", %{conn: conn} do
    field_fixture("e_way_bill", %{"label" => "Driver", "type" => "text"})
    invoice = invoice()

    {:ok, view, _html} = live(conn, ~p"/e-way-bills/new")
    assert has_element?(view, "#e-way-bill-custom-fields")

    assert {:error, {:redirect, _to}} =
             view
             |> form("#ewb-form",
               e_way_bill: %{
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
                 "distance_km" => "150",
                 "custom_fields" => %{"driver" => "R. Kumar"}
               }
             )
             |> render_submit()

    assert EWayBills.live_bill_for_invoice(invoice.id).custom_fields == %{"driver" => "R. Kumar"}
  end

  test "a profile's fields are saved and carried to the invoices it issues", %{conn: conn} do
    scope = owner_scope()

    profile_plan =
      field_fixture(
        "recurring_profile",
        %{"label" => "Plan", "type" => "select", "choices" => [%{"label" => "Gold"}]},
        scope
      )

    field_fixture(
      "invoice",
      %{"label" => "Plan", "type" => "select", "choices" => [%{"label" => "gold"}]},
      scope
    )

    client = client_fixture()

    {:ok, view, _html} = live(conn, ~p"/recurring")
    render_click(view, "toggle_modal", %{})
    assert has_element?(view, "#recurring-custom-fields")

    view
    |> form("#recurring-profile-form", %{
      "recurring_profile" => %{
        "title" => "Gold retainer",
        "client_id" => to_string(client.id),
        "frequency" => "Monthly",
        "next_run_date" => Date.to_iso8601(Date.utc_today()),
        "custom_fields" => %{"plan" => choice_id(profile_plan, "Gold")}
      }
    })
    |> render_submit()

    assert [profile] = Recurring.list_profiles()
    assert %{"plan" => _gold} = profile.custom_fields

    assert {:ok, invoice} = Recurring.process_profile(profile)
    [invoice_plan] = QuantumBilling.CustomFields.active_definitions("invoice")
    assert invoice.custom_fields == %{"plan" => choice_id(invoice_plan, "gold")}
  end
end
