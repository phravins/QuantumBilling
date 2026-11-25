defmodule QuantumBillingWeb.API.ThreeDecimalTest do
  @moduledoc """
  A BHD business through the API and the CSV export: amounts go in and come
  out as fils (1000 to the dinar), never scaled by ten, and every document
  says how many decimals its currency has.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.AccountsFixtures
  import QuantumBilling.ApiFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.Clients
  alias QuantumBilling.Currency
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBilling.TaxRates

  setup do
    user = owner_fixture()
    business = Businesses.default!()

    scope =
      Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))

    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{"tax_regime" => "vat", "vat_country" => "BH", "vat_number" => "200000000000003"},
        :tax
      )

    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{"company_name" => "Manama Traders", "currency" => Currency.label("BHD")},
        :general
      )

    {:ok, _rates} = TaxRates.ensure_presets(scope, "BH")

    client =
      client_fixture(%{
        "name" => "Gulf Trading LLC",
        "phone_country_code" => "+971",
        "phone" => "501234567",
        "billing_city" => "Dubai",
        "billing_state" => "",
        "billing_pin" => "",
        "country" => "AE"
      })

    %{owner: user, client: client}
  end

  defp create_invoice(owner, client) do
    {raw, _key} = api_key_fixture(["invoices:write"], %{owner: owner})

    body = %{
      "client_id" => client.id,
      "invoice_type" => "Tax Invoice",
      "invoice_date" => "2026-11-02",
      "items" => [%{"description" => "Steel fittings", "quantity" => 2, "rate" => 12_345}]
    }

    raw |> api_conn() |> api_post(~p"/api/v1/invoices", body) |> json_response(201)
  end

  test "an invoice takes its rate in fils and says it has three decimals", %{
    owner: owner,
    client: client
  } do
    %{"data" => data} = create_invoice(owner, client)

    assert data["currency"] == "BHD"
    assert data["currency_exponent"] == 3
    # 2 × 12.345 = 24.690, and 10% VAT is 2.469.
    assert [%{"rate" => 12_345, "amount" => 24_690}] = data["items"]
    assert data["amounts"]["taxable_value"] == 24_690
    assert data["amounts"]["vat"] == 2_469
    assert data["amounts"]["grand_total"] == 27_159

    assert [%{rate: 12_345}] = Invoices.get_invoice!(data["id"]).items
  end

  test "a credit note takes and returns fils, with its currency", %{owner: owner, client: client} do
    %{"data" => %{"id" => id}} = create_invoice(owner, client)
    {raw, _key} = api_key_fixture(["credit_notes:write"], %{owner: owner})

    conn =
      raw
      |> api_conn()
      |> api_post(~p"/api/v1/invoices/#{id}/credit-notes", %{
        "type" => "credit",
        "reason" => "Damaged goods",
        "grand_total" => 11_000
      })

    assert %{"data" => data} = json_response(conn, 201)
    assert data["currency"] == "BHD"
    assert data["currency_exponent"] == 3
    assert data["amounts"]["grand_total"] == 11_000
    assert data["amounts"]["subtotal"] + data["amounts"]["tax_total"] == 11_000
  end

  test "a client says which currency its money custom fields are in", %{
    owner: owner,
    client: client
  } do
    scope =
      Scope.put_membership(
        Scope.for_user(owner),
        Businesses.get_membership(owner, Businesses.default!().id)
      )

    {:ok, _} =
      CustomFields.create_definition(scope, "client", %{"label" => "Deposit", "type" => "money"})

    {:ok, client} = Clients.update_client(client, %{"custom_fields" => %{"deposit" => "5.125"}})

    {raw, _key} = api_key_fixture(["clients:read"], %{owner: owner})

    data =
      raw
      |> api_conn()
      |> get(~p"/api/v1/clients/#{client.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["currency"] == "BHD"
    assert data["currency_exponent"] == 3
    assert data["custom_fields"]["deposit"] == 5_125
  end

  test "the sales register CSV shows three decimals", %{conn: conn, owner: owner, client: client} do
    create_invoice(owner, client)

    body =
      conn
      |> log_in_user(owner)
      # "All Time", so the fixed invoice date is in range whatever year it runs.
      |> get(~p"/reports/export?#{[report_type: "Sales Register", date_range: "All Time"]}")
      |> response(200)

    assert body =~ "24.690"
    assert body =~ "27.159"
  end
end
