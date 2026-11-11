defmodule QuantumBillingWeb.API.VATTest do
  @moduledoc """
  The API for a VAT business: lines take `tax_rate_id`, the invoice may be
  reverse-charged, and responses carry the VAT; GST fields are refused, and a
  GST business refuses the VAT ones.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.AccountsFixtures
  import QuantumBilling.ApiFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBilling.TaxRates

  @client_trn "100200300400003"

  setup do
    user = owner_fixture()
    business = Businesses.default!()

    scope =
      Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))

    %{owner: user, scope: scope}
  end

  defp use_vat(%{scope: scope}) do
    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => "100123456700003"},
        :tax
      )

    {:ok, _rates} = TaxRates.ensure_presets(scope, "AE")

    client =
      client_fixture(%{
        "name" => "Gulf Trading LLC",
        "phone_country_code" => "+971",
        "phone" => "501234567",
        "billing_city" => "Dubai",
        "billing_state" => "",
        "billing_pin" => "",
        "country" => "AE",
        "tax_number" => @client_trn
      })

    %{client: client}
  end

  defp rate(name), do: Enum.find(TaxRates.list_rates(), &(&1.name == name)).id

  defp body(client, items, over \\ %{}) do
    Map.merge(
      %{
        "client_id" => client.id,
        "invoice_type" => "Tax Invoice",
        "invoice_date" => "2026-11-02",
        "items" => items
      },
      over
    )
  end

  defp create(owner, body) do
    {raw, _key} = api_key_fixture(["invoices:write"], %{owner: owner})
    raw |> api_conn() |> api_post(~p"/api/v1/invoices", body)
  end

  describe "a VAT business" do
    setup :use_vat

    test "creates an invoice with VAT by rate", %{owner: owner, client: client} do
      items = [
        %{
          "description" => "Consulting",
          "quantity" => 1,
          "rate" => 100_000,
          "tax_rate_id" => rate("Standard 5%")
        },
        %{
          "description" => "Export",
          "quantity" => 1,
          "rate" => 50_000,
          "tax_rate_id" => rate("Zero-rated")
        }
      ]

      data = owner |> create(body(client, items)) |> json_response(201) |> Map.fetch!("data")

      assert data["tax_regime"] == "vat"
      assert data["reverse_charge"] == false
      assert data["place_of_supply"] == nil
      assert data["client"]["tax_number"] == @client_trn
      assert data["amounts"]["vat"] == 5_000
      assert data["amounts"]["grand_total"] == 155_000
      assert data["amounts"]["cgst"] == 0

      assert [
               %{"name" => "Standard 5%", "rate_bp" => 500, "taxable" => 100_000, "tax" => 5_000},
               %{"category" => "zero", "tax" => 0}
             ] = data["tax_breakdown"]

      assert [%{"tax_rate_bp" => 500, "tax_category" => "standard"}, %{"tax_rate_bp" => 0}] =
               data["items"]

      assert Invoices.get_invoice!(data["id"]).vat_amount == 5_000
    end

    test "a line without a rate takes the default", %{owner: owner, client: client} do
      items = [%{"description" => "Consulting", "quantity" => 1, "rate" => 100_000}]

      data = owner |> create(body(client, items)) |> json_response(201) |> Map.fetch!("data")

      assert [%{"tax_rate_id" => id, "tax_name" => "Standard 5%"}] = data["items"]
      assert id == TaxRates.default_rate().id
    end

    test "reverse charge takes the VAT off", %{owner: owner, client: client} do
      items = [%{"description" => "Consulting", "quantity" => 1, "rate" => 100_000}]

      data =
        owner
        |> create(body(client, items, %{"reverse_charge" => true}))
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["reverse_charge"] == true
      assert data["amounts"]["vat"] == 0
      assert data["amounts"]["grand_total"] == 100_000
    end

    test "a GST slab is refused by name", %{owner: owner, client: client} do
      items = [%{"description" => "Consulting", "quantity" => 1, "rate" => 100, "tax_rate" => 18}]

      assert %{"error" => %{"fields" => %{"items.0.tax_rate" => [message]}}} =
               owner |> create(body(client, items)) |> json_response(422)

      assert message =~ "tax_rate_id"
    end

    test "an unknown rate is refused", %{owner: owner, client: client} do
      items = [
        %{"description" => "Consulting", "quantity" => 1, "rate" => 100, "tax_rate_id" => 999_999}
      ]

      assert %{"error" => %{"fields" => %{"items" => [%{"tax_rate_id" => [_message]}]}}} =
               owner |> create(body(client, items)) |> json_response(422)
    end

    test "a client is created with its VAT number", %{owner: owner} do
      {raw, _key} = api_key_fixture(["clients:write"], %{owner: owner})

      body = %{
        "type" => "Registered Business",
        "name" => "Emirates Supplies",
        "phone_country_code" => "+971",
        "phone" => "501234567",
        "country" => "ae",
        "tax_number" => "100-2003-0040-0003",
        "billing_address" => %{"line1" => "Office 4", "city" => "Abu Dhabi"}
      }

      data =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/clients", body)
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["country"] == "AE"
      assert data["tax_number"] == @client_trn
    end
  end

  test "a GST business refuses the VAT fields", %{owner: owner} do
    client = client_fixture()

    body = %{
      "client_id" => client.id,
      "invoice_type" => "Tax Invoice",
      "invoice_date" => "2026-11-02",
      "place_of_supply" => "Maharashtra (27)",
      "reverse_charge" => true,
      "items" => [
        %{"description" => "Consulting", "quantity" => 1, "rate" => 100, "tax_rate_id" => 1}
      ]
    }

    assert %{"error" => %{"fields" => fields}} = owner |> create(body) |> json_response(422)
    assert ["is for VAT invoices; this business charges GST"] = fields["reverse_charge"]
  end
end
