defmodule QuantumBillingWeb.API.WritesTest do
  @moduledoc """
  Creating invoices and clients through the API: what a caller may set, what
  it may not, and what a retry does.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Ecto.Query
  import QuantumBilling.ApiFixtures

  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  defp invoice_body(client, overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => client.id,
        "invoice_type" => "Tax Invoice",
        "invoice_date" => "2026-10-01",
        "place_of_supply" => "Maharashtra (27)",
        "items" => [
          %{
            "description" => "Consulting",
            "hsn_sac" => "998313",
            "quantity" => 2,
            "unit" => "Nos",
            "rate" => 5000,
            "tax_rate" => 18
          }
        ]
      },
      overrides
    )
  end

  defp invoice_count, do: Repo.aggregate(Invoice, :count)

  describe "POST /api/v1/invoices" do
    test "creates an invoice, numbered by the server, with the client taken from the record" do
      {raw, _key} = api_key_fixture(["invoices:write"])
      client = client_fixture(%{"email" => "ap@customer.example"})

      conn = raw |> api_conn() |> api_post(~p"/api/v1/invoices", invoice_body(client))

      assert %{"data" => data} = json_response(conn, 201)
      invoice = Invoices.get_invoice(data["id"])

      assert invoice.client_id == client.id
      assert invoice.client_name == client.name
      assert invoice.client_email == "ap@customer.example"
      assert invoice.client_state == client.billing_state
      assert invoice.status == "Draft"
      assert is_binary(invoice.invoice_number)
      assert data["number"] == invoice.invoice_number
      assert [%{"description" => "Consulting", "quantity" => 2, "rate" => 5000}] = data["items"]
      assert data["amounts"]["taxable_value"] == 10_000
    end

    test "refuses, by name, every field the application sets for itself" do
      {raw, _key} = api_key_fixture(["invoices:write"])
      client = client_fixture()

      # Each of these, if accepted, would let a caller forge something:
      # a paid invoice, a government registration, a phishing payment link,
      # someone else's GSTIN on the document, a number out of series.
      forged = %{
        "status" => "Paid",
        "irn" => "f" <> String.duplicate("0", 63),
        "ack_number" => "112010000000001",
        "signed_qr_code" => "forged",
        "signed_invoice" => "forged",
        "razorpay_payment_url" => "https://evil.example/pay",
        "razorpay_payment_id" => "pay_forged",
        "razorpay_payment_link_id" => "plink_forged",
        "public_token" => "chosen-token",
        "invoice_number" => "INV-0001",
        "client_name" => "Somebody Else Ltd",
        "client_gstin" => "29AAAAA0000A1Z5",
        "company_name" => "Impostor Pvt Ltd",
        "company_gstin" => "27BBBBB0000B1Z5",
        "layout_xml" => "<layout/>",
        "template_id" => 1,
        "currency" => "USD",
        "exchange_rate" => "1",
        "deleted_at" => nil,
        "id" => 1
      }

      for {field, value} <- forged do
        before = invoice_count()

        conn =
          raw
          |> api_conn()
          |> api_post(~p"/api/v1/invoices", invoice_body(client, %{field => value}))

        assert %{"error" => %{"code" => "validation_failed", "fields" => fields}} =
                 json_response(conn, 422),
               "#{field} was accepted"

        assert fields[field] == ["is not accepted by the API"]
        assert invoice_count() == before
      end
    end

    test "refuses unknown fields on a line, too" do
      {raw, _key} = api_key_fixture(["invoices:write"])
      client = client_fixture()

      body =
        invoice_body(client, %{
          "items" => [%{"description" => "x", "rate" => 1, "amount" => 999_999_999}]
        })

      conn = raw |> api_conn() |> api_post(~p"/api/v1/invoices", body)

      assert json_response(conn, 422)["error"]["fields"] == %{
               "items.0.amount" => ["is not accepted by the API"]
             }
    end

    test "a client that does not exist, or is in the Bin, is a field error" do
      {raw, _key} = api_key_fixture(["invoices:write"])
      binned = client_fixture()
      {:ok, _} = QuantumBilling.Clients.delete_client(binned)

      for client_id <- [999_999_999, binned.id, "abc"] do
        conn =
          raw
          |> api_conn()
          |> api_post(~p"/api/v1/invoices", invoice_body(%{id: client_id}))

        assert %{"client_id" => [_]} = json_response(conn, 422)["error"]["fields"]
      end
    end

    test "is recorded in the audit log against the key and the caller's address" do
      {raw, key} = api_key_fixture(["invoices:write"])

      conn = raw |> api_conn() |> api_post(~p"/api/v1/invoices", invoice_body(client_fixture()))
      id = json_response(conn, 201)["data"]["id"]

      log =
        Repo.one!(
          from l in AuditLog,
            where: l.action == "invoice_created" and l.resource_id == ^to_string(id)
        )

      assert log.api_key_id == key.id
      assert log.user_id == nil
      assert log.ip_address == "127.0.0.1"
    end
  end

  describe "idempotency" do
    test "a write without an Idempotency-Key is refused before anything happens" do
      {raw, _key} = api_key_fixture(["invoices:write"])
      client = client_fixture()
      before = invoice_count()

      conn =
        raw
        |> api_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/invoices", Jason.encode!(invoice_body(client)))

      assert json_response(conn, 400)["error"]["code"] == "idempotency_key_required"
      assert invoice_count() == before
    end

    test "a retry with the same key returns the first response and creates nothing" do
      {raw, _key} = api_key_fixture(["invoices:write"])
      body = invoice_body(client_fixture())
      before = invoice_count()

      first = raw |> api_conn() |> api_post(~p"/api/v1/invoices", body, "retry-1")
      second = raw |> api_conn() |> api_post(~p"/api/v1/invoices", body, "retry-1")

      assert first.status == 201
      assert second.status == 201
      assert second.resp_body == first.resp_body
      assert get_resp_header(second, "idempotent-replayed") == ["true"]
      assert invoice_count() == before + 1
    end

    test "the same key with a different body is refused, not replayed" do
      {raw, _key} = api_key_fixture(["invoices:write"])
      client = client_fixture()

      first = raw |> api_conn() |> api_post(~p"/api/v1/invoices", invoice_body(client), "k")

      second =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/invoices", invoice_body(client, %{"remarks" => "changed"}), "k")

      assert first.status == 201
      assert json_response(second, 422)["error"]["code"] == "idempotency_mismatch"
    end

    test "keys are per API key: another integration's key never replays this one's response" do
      {raw_a, _} = api_key_fixture(["invoices:write"])
      {raw_b, _} = api_key_fixture(["invoices:write"])
      body = invoice_body(client_fixture())

      a = raw_a |> api_conn() |> api_post(~p"/api/v1/invoices", body, "shared")
      b = raw_b |> api_conn() |> api_post(~p"/api/v1/invoices", body, "shared")

      assert a.status == 201
      assert b.status == 201
      refute json_response(a, 201)["data"]["id"] == json_response(b, 201)["data"]["id"]
      assert get_resp_header(b, "idempotent-replayed") == []
    end

    test "a validation failure is replayed as the same failure" do
      {raw, _key} = api_key_fixture(["invoices:write"])
      body = invoice_body(client_fixture(), %{"place_of_supply" => "Atlantis"})

      first = raw |> api_conn() |> api_post(~p"/api/v1/invoices", body, "bad")
      second = raw |> api_conn() |> api_post(~p"/api/v1/invoices", body, "bad")

      assert first.status == 422
      assert second.status == 422
      assert second.resp_body == first.resp_body
    end

    test "an over-long key is refused" do
      {raw, _key} = api_key_fixture(["invoices:write"])

      conn =
        raw
        |> api_conn()
        |> api_post(
          ~p"/api/v1/invoices",
          invoice_body(client_fixture()),
          String.duplicate("k", 256)
        )

      assert json_response(conn, 400)["error"]["code"] == "idempotency_key_required"
    end
  end

  describe "POST /api/v1/clients" do
    defp client_body(overrides \\ %{}) do
      Map.merge(
        %{
          "type" => "Unregistered",
          "name" => "Northwind Traders",
          "phone" => "9876543210",
          "email" => "accounts@northwind.example",
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

    test "creates a client in the shape the API returns" do
      {raw, key} = api_key_fixture(["clients:write"])

      conn = raw |> api_conn() |> api_post(~p"/api/v1/clients", client_body())

      assert %{"data" => data} = json_response(conn, 201)
      assert data["name"] == "Northwind Traders"
      assert data["billing_address"]["city"] == "Kochi"
      assert data["shipping_address"] == data["billing_address"]

      client = Repo.get!(Client, data["id"])
      assert client.status == "Active"
      assert client.credit_limit == 0
      assert client.opening_balance == 0

      assert Repo.exists?(
               from l in AuditLog,
                 where: l.action == "client_created" and l.api_key_id == ^key.id
             )
    end

    test "refuses the fields a person decides in the application" do
      {raw, _key} = api_key_fixture(["clients:write"])

      for {field, value} <- [
            {"status", "Inactive"},
            {"notes", "x"},
            {"credit_limit", 10_000_000},
            {"opening_balance", 5},
            {"outstanding", 5}
          ] do
        conn = raw |> api_conn() |> api_post(~p"/api/v1/clients", client_body(%{field => value}))

        assert json_response(conn, 422)["error"]["fields"][field] == [
                 "is not accepted by the API"
               ]
      end
    end

    test "refuses unknown address fields" do
      {raw, _key} = api_key_fixture(["clients:write"])

      body =
        client_body(%{
          "billing_address" => %{
            "line1" => "1",
            "city" => "K",
            "state" => "Kerala (32)",
            "pin" => "682001",
            "gps" => "x"
          }
        })

      conn = raw |> api_conn() |> api_post(~p"/api/v1/clients", body)

      assert json_response(conn, 422)["error"]["fields"] == %{
               "billing_address.gps" => ["is not accepted by the API"]
             }
    end
  end
end
