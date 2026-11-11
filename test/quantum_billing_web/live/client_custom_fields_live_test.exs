defmodule QuantumBillingWeb.ClientCustomFieldsLiveTest do
  @moduledoc "Client custom fields in the form, on the detail page, and in the list."
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.ApiFixtures, only: [client_fixture: 0]
  import QuantumBilling.CustomFieldsFixtures

  alias QuantumBilling.Clients

  setup :register_and_log_in_user

  setup do
    region =
      field_fixture("client", %{
        "label" => "Region",
        "type" => "select",
        "show_in_list" => true,
        "filterable" => true,
        "choices" => [%{"label" => "North"}, %{"label" => "South"}]
      })

    limit = field_fixture("client", %{"label" => "Credit limit", "type" => "money"})
    %{region: region, limit: limit}
  end

  defp client_params(custom) do
    %{
      "client_type" => "Unregistered",
      "name" => "Northwind Traders",
      "phone" => "9876543210",
      "billing_line1" => "7 Harbour Road",
      "billing_city" => "Kochi",
      "billing_state" => "Kerala (32)",
      "billing_pin" => "682001",
      "custom_fields" => custom
    }
  end

  test "the form saves custom fields and edit shows them back", %{conn: conn, region: region} do
    north = choice_id(region, "North")
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    assert has_element?(view, "#client-custom-fields")

    view
    |> form("#client-form", %{
      "client" => client_params(%{"region" => north, "credit_limit" => "25000.50"})
    })
    |> render_submit()

    assert [client] = Clients.list_clients()
    assert client.custom_fields == %{"region" => north, "credit_limit" => 2_500_050}

    {:ok, edit, _html} = live(conn, ~p"/clients/#{client.id}/edit")

    assert has_element?(
             edit,
             ~s(select[name="client[custom_fields][region]"] option[selected][value="#{north}"])
           )

    assert has_element?(
             edit,
             ~s(input[name="client[custom_fields][credit_limit]"][value="25000.50"])
           )
  end

  test "an invalid value is shown inline and nothing is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    view
    |> form("#client-form", %{"client" => client_params(%{"credit_limit" => "lots"})})
    |> render_submit()

    assert Clients.list_clients() == []
    assert has_element?(view, "[id$='_custom_fields_credit_limit-wrapper'] .qb-field-error")
  end

  test "the detail page lists the values", %{conn: conn, region: region} do
    {:ok, client} =
      Clients.update_client(client_fixture(), %{
        "custom_fields" => %{"region" => "South", "credit_limit" => "100"}
      })

    {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

    assert has_element?(view, "#client-custom-values-region", "South")
    assert has_element?(view, "#client-custom-values-credit_limit")
    assert client.custom_fields["region"] == choice_id(region, "South")
  end

  test "the list shows a column and filters by a choice", %{conn: conn, region: region} do
    {:ok, north} =
      Clients.update_client(client_fixture(), %{"custom_fields" => %{"region" => "North"}})

    south = client_fixture()

    {:ok, view, _html} = live(conn, ~p"/clients")

    assert has_element?(view, "#client-col-region")
    assert has_element?(view, "#client-#{north.id}", "North")
    assert has_element?(view, "#client-#{south.id}")

    view
    |> element("#client-custom-filters-region-#{choice_id(region, "North")}")
    |> render_click()

    assert has_element?(view, "#client-#{north.id}")
    refute has_element?(view, "#client-#{south.id}")

    view |> element("#client-custom-filters-region-any") |> render_click()
    assert has_element?(view, "#client-#{south.id}")
  end
end
