defmodule QuantumBillingWeb.API.LeakTest do
  @moduledoc """
  What the API says about a record, and what it must never say.

  The field lists are pinned exactly: a column added to a table later does not
  reach the API until someone changes the serializer *and* this test. The
  sweep then plants a recognisable value in every sensitive column and checks
  that none of them comes out of any endpoint.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.ApiFixtures

  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  @invoice_keys ~w(id number type status invoice_date due_date payment_terms place_of_supply
                   currency client amounts e_invoice remarks terms created_at updated_at)
  @client_keys ~w(id type name display_name legal_name gstin pan business_type category email
                  phone billing_address shipping_address payment_terms_days status created_at
                  updated_at)
  @bill_keys ~w(id number date valid_until status distance_km mode_of_transport vehicle_number
                transporter_id transporter_name cancelled_at cancellation_reason invoice
                created_at updated_at)

  # Values that cannot occur by accident, one per column that must stay inside.
  @secrets %{
    public_token: "tok_PUBLICTOKENLEAK0001",
    signed_invoice: "SIGNEDINVOICELEAK0002",
    signed_qr_code: "SIGNEDQRLEAK0003",
    layout_xml: "<layout>LAYOUTLEAK0004</layout>",
    razorpay_payment_url: "https://rzp.io/i/PAYURLLEAK0005",
    razorpay_payment_link_id: "plink_LINKIDLEAK0006",
    razorpay_payment_id: "pay_PAYIDLEAK0007",
    client_email: "invoice-copy-LEAK0008@customer.example",
    client_billing_address: "ADDRESSLEAK0009 Street"
  }

  setup do
    invoice = invoice_fixture(@secrets)
    bill = e_way_bill_fixture(invoice)

    client =
      client_fixture(%{"notes" => "PRIVATENOTELEAK0010", "opening_balance" => "777001"})

    Settings.ensure_organization()
    |> Ecto.Changeset.change(webhook_secret: "whsec_WEBHOOKSECRETLEAK0011")
    |> Repo.update!()

    %{invoice: invoice, bill: bill, client: client}
  end

  defp everything(raw, %{invoice: invoice, bill: bill, client: client}) do
    conn = api_conn(raw)

    [
      get(conn, ~p"/api/v1/me"),
      get(conn, ~p"/api/v1/invoices"),
      get(conn, ~p"/api/v1/invoices/#{invoice.id}"),
      get(conn, ~p"/api/v1/clients"),
      get(conn, ~p"/api/v1/clients/#{client.id}"),
      get(conn, ~p"/api/v1/e-way-bills"),
      get(conn, ~p"/api/v1/e-way-bills/#{bill.id}")
    ]
    |> Enum.map(fn conn ->
      assert conn.status == 200
      conn.resp_body
    end)
    |> Enum.join("\n")
  end

  describe "field lists" do
    test "an invoice has exactly its documented fields", %{invoice: invoice} do
      {raw, _key} = api_key_fixture(["invoices:read"])

      listed = raw |> api_conn() |> get(~p"/api/v1/invoices") |> json_response(200)
      shown = raw |> api_conn() |> get(~p"/api/v1/invoices/#{invoice.id}") |> json_response(200)

      assert listed["data"] |> hd() |> Map.keys() |> Enum.sort() == Enum.sort(@invoice_keys)
      assert shown["data"] |> Map.keys() |> Enum.sort() == Enum.sort(["items" | @invoice_keys])
      assert shown["data"]["client"] |> Map.keys() |> Enum.sort() == ~w(gstin id name state)
    end

    test "a client has exactly its documented fields", %{client: client} do
      {raw, _key} = api_key_fixture(["clients:read"])

      shown = raw |> api_conn() |> get(~p"/api/v1/clients/#{client.id}") |> json_response(200)

      assert shown["data"] |> Map.keys() |> Enum.sort() == Enum.sort(@client_keys)
    end

    test "an e-way bill has exactly its documented fields", %{bill: bill} do
      {raw, _key} = api_key_fixture(["e_way_bills:read"])

      shown = raw |> api_conn() |> get(~p"/api/v1/e-way-bills/#{bill.id}") |> json_response(200)

      assert shown["data"] |> Map.keys() |> Enum.sort() == Enum.sort(@bill_keys)
      assert shown["data"]["invoice"] |> Map.keys() |> Enum.sort() == ~w(id number)
    end

    test "the serializers' own lists match the ones pinned here" do
      assert Enum.map(QuantumBillingWeb.API.V1.InvoiceJSON.fields(), &to_string/1) ==
               @invoice_keys

      assert Enum.map(QuantumBillingWeb.API.V1.ClientJSON.fields(), &to_string/1) == @client_keys
      assert Enum.map(QuantumBillingWeb.API.V1.EWayBillJSON.fields(), &to_string/1) == @bill_keys
    end
  end

  describe "the sweep" do
    test "no endpoint returns a sensitive value, to a key holding every read scope", records do
      {raw, key} =
        api_key_fixture(["invoices:read", "clients:read", "e_way_bills:read"])

      body = everything(raw, records)

      for {column, value} <- @secrets do
        refute body =~ value, "#{column} leaked through the API"
      end

      refute body =~ "PRIVATENOTELEAK0010", "client notes leaked"
      refute body =~ "777001", "opening balance leaked"
      refute body =~ "WEBHOOKSECRETLEAK0011", "the webhook secret leaked"
      refute body =~ raw, "the key itself leaked"
      refute body =~ Base.encode64(key.hashed_key), "the key hash leaked"
      refute body =~ Base.encode16(key.hashed_key, case: :lower), "the key hash leaked"
      refute body =~ "deleted_at"
    end

    test "the payment link appears only with invoices:payment_links", records do
      %{invoice: invoice} = records
      {plain, _key} = api_key_fixture(["invoices:read"])
      {linked, _key} = api_key_fixture(["invoices:read", "invoices:payment_links"])

      plain_body = plain |> api_conn() |> get(~p"/api/v1/invoices/#{invoice.id}")
      linked_body = linked |> api_conn() |> get(~p"/api/v1/invoices/#{invoice.id}")

      refute Map.has_key?(json_response(plain_body, 200)["data"], "payment_url")

      # The slugged link, which names the business the invoice belongs to.
      slug = QuantumBilling.Businesses.default!().slug

      assert json_response(linked_body, 200)["data"]["payment_url"] ==
               url(~p"/p/#{slug}/#{invoice.public_token}")

      # The link is to this application's own page, never the gateway URL
      # stored on the invoice — that one is set by the gateway, and the page
      # decides whether to send the customer there.
      refute linked_body.resp_body =~ @secrets.razorpay_payment_url
    end

    test "the customer's contact details on an invoice are not readable with invoices:read", %{
      invoice: invoice
    } do
      {raw, _key} = api_key_fixture(["invoices:read"])

      body = raw |> api_conn() |> get(~p"/api/v1/invoices/#{invoice.id}") |> Map.get(:resp_body)

      refute body =~ @secrets.client_email
      refute body =~ @secrets.client_billing_address
    end
  end

  describe "errors" do
    test "a validation error never echoes the submitted value" do
      {raw, _key} = api_key_fixture(["clients:write"])
      planted = "not-an-email-ECHOLEAK0012"

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/clients", %{
          "type" => "Unregistered",
          "name" => "Echo Co",
          "phone" => "9876543210",
          "email" => planted,
          "billing_address" => %{
            "line1" => "1 Road",
            "city" => "Mumbai",
            "state" => "Maharashtra (27)",
            "pin" => "400001"
          }
        })

      assert %{"error" => %{"fields" => %{"email" => [_ | _]}}} = json_response(conn, 422)
      refute conn.resp_body =~ "ECHOLEAK0012"
    end

    test "a request for a record that does not exist says only that" do
      {raw, _key} = api_key_fixture(["invoices:read"])

      for id <- ["999999999", "abc", "1;DROP TABLE invoices"] do
        conn = raw |> api_conn() |> get("/api/v1/invoices/#{URI.encode_www_form(id)}")

        assert %{"error" => %{"code" => "not_found", "message" => "No such invoice."}} =
                 json_response(conn, 404)
      end
    end
  end

  test "a key that has expired does not keep working through a stale assign" do
    {raw, key} = api_key_fixture(["invoices:read"])
    assert raw |> api_conn() |> get(~p"/api/v1/me") |> Map.get(:status) == 200

    key |> ApiKey.revoke_changeset() |> Repo.update!()

    assert raw |> api_conn() |> get(~p"/api/v1/me") |> Map.get(:status) == 401
  end
end
