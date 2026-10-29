defmodule QuantumBillingWeb.API.ReadsTest do
  @moduledoc """
  Lists and lookups: the Bin stays hidden, and paging cannot be used to pull a
  table in one call or to loop forever.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.ApiFixtures

  alias QuantumBilling.{Clients, EWayBills, Invoices}

  defp ids(conn), do: conn |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["id"])

  describe "the Bin" do
    test "a binned invoice, client and e-way bill are absent from lists and 404 by id" do
      {raw, _key} = api_key_fixture(["invoices:read", "clients:read", "e_way_bills:read"])
      conn = api_conn(raw)

      kept_invoice = invoice_fixture()
      binned_invoice = invoice_fixture()
      {:ok, _} = Invoices.delete_invoice(binned_invoice)

      kept_client = client_fixture()
      binned_client = client_fixture()
      {:ok, _} = Clients.delete_client(binned_client)

      kept_bill = e_way_bill_fixture()
      binned_bill = e_way_bill_fixture()
      {:ok, _} = EWayBills.delete_e_way_bill(binned_bill)

      refute binned_invoice.id in ids(get(conn, ~p"/api/v1/invoices?per_page=100"))
      assert kept_invoice.id in ids(get(conn, ~p"/api/v1/invoices?per_page=100"))
      refute binned_client.id in ids(get(conn, ~p"/api/v1/clients?per_page=100"))
      assert kept_client.id in ids(get(conn, ~p"/api/v1/clients?per_page=100"))
      refute binned_bill.id in ids(get(conn, ~p"/api/v1/e-way-bills?per_page=100"))
      assert kept_bill.id in ids(get(conn, ~p"/api/v1/e-way-bills?per_page=100"))

      assert get(conn, ~p"/api/v1/invoices/#{binned_invoice.id}").status == 404
      assert get(conn, ~p"/api/v1/clients/#{binned_client.id}").status == 404
      assert get(conn, ~p"/api/v1/e-way-bills/#{binned_bill.id}").status == 404
    end

    test "a binned record is indistinguishable from one that never existed" do
      {raw, _key} = api_key_fixture(["invoices:read"])
      binned = invoice_fixture()
      {:ok, _} = Invoices.delete_invoice(binned)

      gone = raw |> api_conn() |> get(~p"/api/v1/invoices/#{binned.id}")
      never = raw |> api_conn() |> get(~p"/api/v1/invoices/999999999")

      assert gone.status == never.status
      assert gone.resp_body == never.resp_body
    end

    test "an e-way bill whose invoice is in the Bin is hidden too" do
      {raw, _key} = api_key_fixture(["e_way_bills:read"])
      invoice = invoice_fixture()
      bill = e_way_bill_fixture(invoice)
      {:ok, _} = Invoices.delete_invoice(invoice)

      conn = api_conn(raw)

      refute bill.id in ids(get(conn, ~p"/api/v1/e-way-bills?per_page=100"))
      assert get(conn, ~p"/api/v1/e-way-bills/#{bill.id}").status == 404
    end
  end

  describe "paging" do
    test "defaults to 25 a page and refuses more than 100" do
      {raw, _key} = api_key_fixture(["invoices:read"])
      conn = api_conn(raw)

      assert json_response(get(conn, ~p"/api/v1/invoices"), 200)["meta"]["per_page"] == 25

      assert json_response(get(conn, ~p"/api/v1/invoices?per_page=100"), 200)["meta"]["per_page"] ==
               100

      assert %{"error" => %{"code" => "invalid_parameters", "fields" => %{"per_page" => _}}} =
               json_response(get(conn, ~p"/api/v1/invoices?per_page=101"), 400)
    end

    test "rejects pages that are not positive whole numbers" do
      {raw, _key} = api_key_fixture(["clients:read"])

      for page <- ["0", "-1", "two", "1.5"] do
        conn = raw |> api_conn() |> get("/api/v1/clients?page=#{page}")
        assert json_response(conn, 400)["error"]["fields"]["page"]
      end
    end

    test "a page past the end is empty, not the last page again" do
      {raw, _key} = api_key_fixture(["clients:read"])
      client_fixture()

      body = raw |> api_conn() |> get(~p"/api/v1/clients?page=9999") |> json_response(200)

      assert body["data"] == []
      assert body["meta"]["page"] == 9999
      assert body["meta"]["total_pages"] < 9999
    end

    test "status and search narrow the list" do
      {raw, _key} = api_key_fixture(["invoices:read"])
      draft = invoice_fixture(%{status: "Draft", client_name: "Zebra Findable Co"})
      paid = invoice_fixture(%{status: "Paid"})
      conn = api_conn(raw)

      drafts = ids(get(conn, ~p"/api/v1/invoices?status=Draft&per_page=100"))
      assert draft.id in drafts
      refute paid.id in drafts

      assert ids(get(conn, ~p"/api/v1/invoices?search=Zebra Findable")) == [draft.id]
    end
  end
end
