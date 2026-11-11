defmodule QuantumBillingWeb.InvoiceCustomFieldsLiveTest do
  @moduledoc "Invoice and line custom fields in the form, on the document page, and in the list."
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import QuantumBilling.ApiFixtures, only: [invoice_fixture: 1]
  import QuantumBilling.CustomFieldsFixtures

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings

  setup :register_and_log_in_user

  setup do
    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{
          "company_name" => "ABC Solutions Private Limited",
          "gstin" => "27AABCA1234A1Z5",
          "pan" => "AABCA1234A",
          "state" => "Maharashtra (27)"
        },
        :general
      )

    scope = owner_scope()
    field_fixture("invoice", %{"label" => "PO number", "type" => "text"}, scope)

    field_fixture(
      "invoice",
      %{"label" => "Urgent", "type" => "boolean", "show_in_list" => true, "filterable" => true},
      scope
    )

    field_fixture("invoice_item", %{"label" => "Batch", "type" => "text"}, scope)
    :ok
  end

  defp params(custom, item_custom) do
    %{
      "invoice_type" => "Tax Invoice",
      "invoice_date" => "2026-10-01",
      "due_date" => "2026-10-16",
      "payment_terms" => "Net 15 Days",
      "place_of_supply" => "Maharashtra (27)",
      "client_name" => "V2V Technologies",
      "client_gstin" => "27AAACP8542D1ZS",
      "custom_fields" => custom,
      "items" => %{
        "0" => %{
          "description" => "Web Development Services",
          "hsn_sac" => "998313",
          "quantity" => "1",
          "unit" => "Nos",
          "rate" => "50000",
          "tax_rate" => "18",
          "position" => "0",
          "custom_fields" => item_custom
        }
      }
    }
  end

  test "saves header and line fields and shows them back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    assert has_element?(view, "#invoice-custom-fields")
    assert has_element?(view, "#invoice-item-fields-0")

    assert {:error, {:live_redirect, %{to: path}}} =
             view
             |> form("#invoice-form", %{
               "invoice" =>
                 params(%{"po_number" => "PO-77", "urgent" => "true"}, %{"batch" => "B-12"})
             })
             |> render_submit()

    [row] = Invoices.list_invoices()
    assert path == "/invoices/#{row.id}"

    invoice = Invoices.get_invoice!(row.id)
    assert invoice.custom_fields == %{"po_number" => "PO-77", "urgent" => true}
    assert [%{custom_fields: %{"batch" => "B-12"}}] = invoice.items

    {:ok, show, _html} = live(conn, path)
    assert has_element?(show, "#invoice-custom-values-po_number", "PO-77")

    {:ok, edit, _html} = live(conn, ~p"/invoices/#{row.id}/edit")
    assert has_element?(edit, ~s(input[name="invoice[custom_fields][po_number]"][value="PO-77"]))

    assert has_element?(
             edit,
             ~s(input[name="invoice[items][0][custom_fields][batch]"][value="B-12"])
           )
  end

  test "the list shows a column and filters by a yes/no field", %{conn: conn} do
    urgent = invoice_fixture(%{custom_fields: %{"urgent" => true}})
    calm = invoice_fixture(%{custom_fields: %{"urgent" => false}})

    {:ok, view, _html} = live(conn, ~p"/invoices")

    assert has_element?(view, "#invoice-col-urgent")
    assert has_element?(view, "#invoice-#{urgent.id}", "Yes")

    view |> element("#invoice-custom-filters-urgent-true") |> render_click()

    assert has_element?(view, "#invoice-#{urgent.id}")
    refute has_element?(view, "#invoice-#{calm.id}")
  end
end
