defmodule QuantumBillingWeb.API.ActionsTest do
  @moduledoc """
  The API's actions on an existing invoice — record a payment, cancel,
  register for an IRN, raise a credit note — and cursor paging.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Ecto.Query
  import QuantumBilling.ApiFixtures

  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  defp invoice(attrs \\ %{}) do
    client = client_fixture()
    invoice_fixture(Map.merge(%{client_id: client.id, grand_total: 118_000}, attrs))
  end

  describe "POST /invoices/:id/payments" do
    test "marks the invoice paid with an external reference, audited to the key" do
      {raw, key} = api_key_fixture(["invoices:payments"])
      invoice = invoice()

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/invoices/#{invoice.id}/payments", %{
          "reference" => "NEFT-0042",
          "amount" => 118_000
        })

      assert json_response(conn, 200)["data"]["status"] == "Paid"

      paid = Repo.get!(Invoice, invoice.id)
      assert paid.status == "Paid"
      assert paid.razorpay_payment_id == "ext:NEFT-0042"

      assert Repo.exists?(
               from l in AuditLog,
                 where: l.action == "payment_received" and l.api_key_id == ^key.id
             )
    end

    test "refuses a partial payment, a second payment and a cancelled invoice" do
      {raw, _key} = api_key_fixture(["invoices:payments"])
      invoice = invoice()
      path = ~p"/api/v1/invoices/#{invoice.id}/payments"

      partial = raw |> api_conn() |> api_post(path, %{"reference" => "R1", "amount" => 100})
      assert %{"amount" => [_]} = json_response(partial, 422)["error"]["fields"]
      assert Repo.get!(Invoice, invoice.id).status == "Draft"

      raw |> api_conn() |> api_post(path, %{"reference" => "R2", "amount" => 118_000})
      again = raw |> api_conn() |> api_post(path, %{"reference" => "R3", "amount" => 118_000})
      assert json_response(again, 409)["error"]["code"] == "already_paid"

      cancelled = invoice(%{status: "Cancelled"})

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/invoices/#{cancelled.id}/payments", %{
          "reference" => "R4",
          "amount" => 118_000
        })

      assert json_response(conn, 409)["error"]["code"] == "cancelled"
    end

    test "refuses unknown fields and a missing reference" do
      {raw, _key} = api_key_fixture(["invoices:payments"])
      path = ~p"/api/v1/invoices/#{invoice().id}/payments"

      conn = raw |> api_conn() |> api_post(path, %{"amount" => 118_000, "status" => "Paid"})
      assert json_response(conn, 422)["error"]["fields"]["status"]

      conn = raw |> api_conn() |> api_post(path, %{"amount" => 118_000})
      assert json_response(conn, 422)["error"]["fields"]["reference"]
    end
  end

  describe "POST /invoices/:id/cancel" do
    test "cancels with a reason, audited, and the invoice leaves the payable states" do
      {raw, key} = api_key_fixture(["invoices:write"])
      invoice = invoice()

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/invoices/#{invoice.id}/cancel", %{"reason" => "Duplicate order"})

      assert json_response(conn, 200)["data"]["status"] == "Cancelled"

      assert Repo.exists?(
               from l in AuditLog,
                 where: l.action == "invoice_cancelled" and l.api_key_id == ^key.id
             )
    end

    test "is refused for a paid invoice, a live IRN and a live e-way bill" do
      {raw, _key} = api_key_fixture(["invoices:write"])

      cases = [
        {invoice(%{status: "Paid"}), "paid"},
        {invoice(%{irn: String.duplicate("a", 64), irn_mode: "live"}), "irn_registered"}
      ]

      with_bill = invoice()
      e_way_bill_fixture(with_bill)

      for {invoice, code} <- cases ++ [{with_bill, "live_e_way_bill"}] do
        conn =
          raw
          |> api_conn()
          |> api_post(~p"/api/v1/invoices/#{invoice.id}/cancel", %{"reason" => "x"})

        assert json_response(conn, 409)["error"]["code"] == code
        refute Repo.get!(Invoice, invoice.id).status == "Cancelled"
      end
    end

    test "a demo IRN does not block cancelling" do
      {raw, _key} = api_key_fixture(["invoices:write"])
      invoice = invoice(%{irn: "demo-irn", irn_mode: "demo"})

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/invoices/#{invoice.id}/cancel", %{"reason" => "x"})

      assert json_response(conn, 200)["data"]["status"] == "Cancelled"
    end
  end

  describe "POST /invoices/:id/e-invoice" do
    test "queues registration and says so; a registered invoice says that instead" do
      {raw, _key} = api_key_fixture(["invoices:e_invoice"])

      registered = invoice(%{irn: String.duplicate("b", 64), irn_mode: "live"})

      conn = raw |> api_conn() |> api_post(~p"/api/v1/invoices/#{registered.id}/e-invoice", %{})
      assert json_response(conn, 200)["data"]["status"] == "already_registered"

      fresh = invoice()
      conn = raw |> api_conn() |> api_post(~p"/api/v1/invoices/#{fresh.id}/e-invoice", %{})
      assert json_response(conn, 202)["data"]["status"] == "queued"
    end

    test "a cancelled or paid invoice is refused, and keeps its status" do
      {raw, _key} = api_key_fixture(["invoices:e_invoice"])

      for {status, code} <- [{"Cancelled", "cancelled"}, {"Paid", "paid"}] do
        invoice = invoice(%{status: status})

        conn = raw |> api_conn() |> api_post(~p"/api/v1/invoices/#{invoice.id}/e-invoice", %{})

        assert json_response(conn, 409)["error"]["code"] == code
        assert Repo.get!(Invoice, invoice.id).status == status
      end
    end

    test "the invoice shows whether its IRN is live or a sandbox one" do
      {raw, _key} = api_key_fixture(["invoices:read"])
      demo = invoice(%{irn: "demo", irn_mode: "demo"})

      body = raw |> api_conn() |> get(~p"/api/v1/invoices/#{demo.id}") |> json_response(200)

      assert body["data"]["e_invoice"]["mode"] == "demo"
    end
  end

  describe "credit notes" do
    test "are raised against an invoice in paise and read back" do
      {raw, key} = api_key_fixture(["credit_notes:write", "credit_notes:read"])
      invoice = invoice()

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/invoices/#{invoice.id}/credit-notes", %{
          "type" => "credit",
          "reason" => "Damaged goods",
          "subtotal" => 10_000,
          "tax_total" => 1_800,
          "grand_total" => 11_800
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["type"] == "credit"

      assert data["amounts"] == %{
               "subtotal" => 10_000,
               "tax_total" => 1_800,
               "grand_total" => 11_800
             }

      assert data["invoice"] == %{"id" => invoice.id, "number" => invoice.invoice_number}

      assert raw
             |> api_conn()
             |> get(~p"/api/v1/credit-notes/#{data["id"]}")
             |> json_response(200)

      assert Repo.exists?(
               from l in AuditLog,
                 where: l.action == "credit_note_created" and l.api_key_id == ^key.id
             )
    end

    test "the serializer's fields are exactly the documented ones" do
      assert QuantumBillingWeb.API.V1.CreditNoteJSON.fields() ==
               ~w(id number type reason status amounts invoice client_id created_at updated_at)a
    end

    test "refuse a bad type and fields the API does not take" do
      {raw, _key} = api_key_fixture(["credit_notes:write"])
      path = ~p"/api/v1/invoices/#{invoice().id}/credit-notes"

      conn = raw |> api_conn() |> api_post(path, %{"type" => "refund", "reason" => "x"})
      assert json_response(conn, 422)["error"]["fields"]["type"]

      conn =
        raw
        |> api_conn()
        |> api_post(path, %{"type" => "credit", "reason" => "x", "status" => "Applied"})

      assert json_response(conn, 422)["error"]["fields"]["status"]
    end

    test "notes on a binned invoice are hidden" do
      {raw, _key} = api_key_fixture(["credit_notes:read"])
      invoice = invoice()
      {:ok, note} = QuantumBilling.CreditNotes.create_credit_note_for_invoice(invoice, %{})
      {:ok, _} = QuantumBilling.Invoices.delete_invoice(invoice)

      assert raw |> api_conn() |> get(~p"/api/v1/credit-notes/#{note.id}") |> Map.get(:status) ==
               404

      ids =
        raw
        |> api_conn()
        |> get(~p"/api/v1/credit-notes")
        |> json_response(200)
        |> Map.fetch!("data")

      refute note.id in Enum.map(ids, & &1["id"])
    end
  end

  describe "cursor paging" do
    test "walks every record exactly once, newest first, to the end" do
      {raw, _key} = api_key_fixture(["clients:read"])
      ids = for _ <- 1..7, do: client_fixture().id

      walk = fn walk, path, acc ->
        body = raw |> api_conn() |> get(path) |> json_response(200)
        acc = acc ++ Enum.map(body["data"], & &1["id"])

        case body["meta"] do
          %{"has_next" => true, "next_cursor" => cursor} ->
            walk.(walk, "/api/v1/clients?per_page=3&cursor=#{cursor}", acc)

          %{"has_next" => false, "next_cursor" => nil} ->
            acc
        end
      end

      seen = walk.(walk, "/api/v1/clients?paginate=cursor&per_page=3", [])

      mine = Enum.filter(seen, &(&1 in ids))
      assert mine == Enum.sort(ids, :desc)
      assert seen == Enum.uniq(seen)
    end

    test "a record created mid-walk does not shift the next page" do
      {raw, _key} = api_key_fixture(["invoices:read"])
      for _ <- 1..4, do: invoice()

      first =
        raw
        |> api_conn()
        |> get("/api/v1/invoices?paginate=cursor&per_page=2")
        |> json_response(200)

      invoice()

      second =
        raw
        |> api_conn()
        |> get("/api/v1/invoices?per_page=2&cursor=#{first["meta"]["next_cursor"]}")
        |> json_response(200)

      first_ids = Enum.map(first["data"], & &1["id"])
      second_ids = Enum.map(second["data"], & &1["id"])
      assert Enum.max(second_ids) < Enum.min(first_ids)
    end

    test "a cursor this API did not issue is refused" do
      {raw, _key} = api_key_fixture(["e_way_bills:read"])

      for cursor <- [
            "garbage",
            Base.url_encode64("v1:abc", padding: false),
            Base.url_encode64("42")
          ] do
        conn = raw |> api_conn() |> get("/api/v1/e-way-bills?cursor=#{cursor}")
        assert json_response(conn, 400)["error"]["fields"]["cursor"]
      end
    end
  end
end
