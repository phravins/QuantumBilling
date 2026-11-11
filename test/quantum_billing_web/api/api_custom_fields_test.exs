defmodule QuantumBillingWeb.API.CustomFieldsTest do
  @moduledoc """
  Custom fields through the API: only fields marked "Include in API" (the
  default) are shown or accepted, and money is integer paise both ways.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.AccountsFixtures
  import QuantumBilling.ApiFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.Clients
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Invoices

  setup do
    user = owner_fixture()
    business = Businesses.default!()

    scope =
      Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))

    field = fn object, attrs ->
      {:ok, definition} = CustomFields.create_definition(scope, object, attrs)
      definition
    end

    field.("client", %{
      "label" => "Region",
      "type" => "select",
      "include_in_api" => true,
      "choices" => [%{"label" => "North"}, %{"label" => "South"}]
    })

    field.("client", %{"label" => "Credit score", "type" => "number", "include_in_api" => false})
    field.("invoice", %{"label" => "Deposit", "type" => "money", "include_in_api" => true})
    field.("invoice_item", %{"label" => "Batch", "type" => "text", "include_in_api" => true})
    %{owner: user}
  end

  defp client_body(overrides) do
    Map.merge(
      %{
        "type" => "Unregistered",
        "name" => "Northwind Traders",
        "phone" => "9876543210",
        "billing_address" => %{
          "line1" => "7 Harbour Road",
          "city" => "Kochi",
          "state" => "Kerala (32)",
          "pin" => "682001"
        }
      },
      overrides
    )
  end

  test "a client shows only the fields marked for the API", %{owner: owner} do
    client = client_fixture()

    {:ok, client} =
      Clients.update_client(client, %{
        "custom_fields" => %{"region" => "North", "credit_score" => "720"}
      })

    {raw, _key} = api_key_fixture(["clients:read"], %{owner: owner})
    shown = raw |> api_conn() |> get(~p"/api/v1/clients/#{client.id}") |> json_response(200)

    assert %{"region" => region} = shown["data"]["custom_fields"]
    assert is_binary(region)
    refute Map.has_key?(shown["data"]["custom_fields"], "credit_score")
  end

  test "a client is created with a choice given by its label", %{owner: owner} do
    {raw, _key} = api_key_fixture(["clients:write"], %{owner: owner})

    body = client_body(%{"custom_fields" => %{"region" => "south"}})

    data =
      raw
      |> api_conn()
      |> api_post(~p"/api/v1/clients", body)
      |> json_response(201)
      |> Map.fetch!("data")

    client = Clients.get_client(data["id"])
    assert client.custom_fields["region"] == data["custom_fields"]["region"]
    assert is_binary(client.custom_fields["region"])
  end

  test "a field not marked for the API is refused by name", %{owner: owner} do
    {raw, _key} = api_key_fixture(["clients:write"], %{owner: owner})

    body = client_body(%{"custom_fields" => %{"credit_score" => "800"}})
    conn = raw |> api_conn() |> api_post(~p"/api/v1/clients", body)

    assert %{"error" => %{"fields" => fields}} = json_response(conn, 422)
    assert Map.has_key?(fields, "custom_fields.credit_score")
  end

  test "an invoice takes money in paise and line fields", %{owner: owner} do
    client = client_fixture()
    {raw, _key} = api_key_fixture(["invoices:write"], %{owner: owner})

    body = %{
      "client_id" => client.id,
      "invoice_type" => "Tax Invoice",
      "invoice_date" => "2026-10-01",
      "place_of_supply" => "Maharashtra (27)",
      "custom_fields" => %{"deposit" => 125_050},
      "items" => [
        %{
          "description" => "Consulting",
          "quantity" => 1,
          "rate" => 5000,
          "tax_rate" => 18,
          "custom_fields" => %{"batch" => "B-12"}
        }
      ]
    }

    data =
      raw
      |> api_conn()
      |> api_post(~p"/api/v1/invoices", body)
      |> json_response(201)
      |> Map.fetch!("data")

    assert data["custom_fields"] == %{"deposit" => 125_050}
    assert [%{"custom_fields" => %{"batch" => "B-12"}}] = data["items"]
    assert Invoices.get_invoice(data["id"]).custom_fields == %{"deposit" => 125_050}
  end

  test "money that is not whole paise is refused", %{owner: owner} do
    client = client_fixture()
    {raw, _key} = api_key_fixture(["invoices:write"], %{owner: owner})

    body = %{
      "client_id" => client.id,
      "invoice_type" => "Tax Invoice",
      "invoice_date" => "2026-10-01",
      "place_of_supply" => "Maharashtra (27)",
      "custom_fields" => %{"deposit" => "12.50"},
      "items" => [%{"description" => "Consulting", "quantity" => 1, "rate" => 5000}]
    }

    conn = raw |> api_conn() |> api_post(~p"/api/v1/invoices", body)

    assert %{"error" => %{"fields" => %{"custom_fields.deposit" => _}}} = json_response(conn, 422)
  end
end
