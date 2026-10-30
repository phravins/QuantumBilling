defmodule QuantumBillingWeb.API.ScopesTest do
  @moduledoc """
  Every route, against a key holding each single scope: exactly the routes the
  scope names answer, and every other one is a 403.

  Walks the table below rather than a handful of examples, so a route added
  later with the wrong `RequireScope` — or none — fails here.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.ApiFixtures

  alias QuantumBilling.ApiKeys.ApiKey

  # {method, route template, path, the scope it needs (nil = any key)}
  defp routes(%{invoice: invoice, client: client, bill: bill, note: note}) do
    i = invoice.id

    [
      {:get, "/api/v1/me", "/api/v1/me", nil},
      {:get, "/api/v1/invoices", "/api/v1/invoices", "invoices:read"},
      {:get, "/api/v1/invoices/:id", "/api/v1/invoices/#{i}", "invoices:read"},
      {:post, "/api/v1/invoices", "/api/v1/invoices", "invoices:write"},
      {:post, "/api/v1/invoices/:id/cancel", "/api/v1/invoices/#{i}/cancel", "invoices:write"},
      {:post, "/api/v1/invoices/:id/payments", "/api/v1/invoices/#{i}/payments",
       "invoices:payments"},
      {:post, "/api/v1/invoices/:id/e-invoice", "/api/v1/invoices/#{i}/e-invoice",
       "invoices:e_invoice"},
      {:post, "/api/v1/invoices/:invoice_id/credit-notes", "/api/v1/invoices/#{i}/credit-notes",
       "credit_notes:write"},
      {:get, "/api/v1/credit-notes", "/api/v1/credit-notes", "credit_notes:read"},
      {:get, "/api/v1/credit-notes/:id", "/api/v1/credit-notes/#{note.id}", "credit_notes:read"},
      {:get, "/api/v1/clients", "/api/v1/clients", "clients:read"},
      {:get, "/api/v1/clients/:id", "/api/v1/clients/#{client.id}", "clients:read"},
      {:post, "/api/v1/clients", "/api/v1/clients", "clients:write"},
      {:get, "/api/v1/e-way-bills", "/api/v1/e-way-bills", "e_way_bills:read"},
      {:get, "/api/v1/e-way-bills/:id", "/api/v1/e-way-bills/#{bill.id}", "e_way_bills:read"}
    ]
  end

  setup do
    client = client_fixture()
    invoice = invoice_fixture(%{client_id: client.id})
    {:ok, note} = QuantumBilling.CreditNotes.create_credit_note_for_invoice(invoice, %{})

    %{invoice: invoice, client: client, bill: e_way_bill_fixture(invoice_fixture()), note: note}
  end

  test "each scope opens exactly its own routes", records do
    for scope <- ApiKey.scopes() do
      {raw, _key} = api_key_fixture([scope])

      for {method, _template, path, needed} <- routes(records) do
        conn =
          case method do
            :get -> raw |> api_conn() |> get(path)
            # An empty body: what matters is whether the scope check lets the
            # request reach validation (422) or stops it first (403).
            :post -> raw |> api_conn() |> api_post(path, %{})
          end

        if is_nil(needed) or needed == scope do
          # 202: the e-invoice action queues; 404 never, the records exist.
          assert conn.status in [200, 202, 422],
                 "#{scope} should reach #{method} #{path}, got #{conn.status}"
        else
          assert conn.status == 403,
                 "#{scope} should be refused #{method} #{path}, got #{conn.status}"

          assert json_response(conn, 403)["error"]["code"] == "insufficient_scope"
        end
      end
    end
  end

  test "the route table above is the whole API", records do
    api_routes =
      QuantumBillingWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/v1/"))
      |> Enum.reject(&(&1.path == "/api/v1/*path"))
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.sort()

    covered =
      records
      |> routes()
      |> Enum.map(fn {method, template, _path, _scope} -> {method, template} end)
      |> Enum.sort()

    assert api_routes == covered
  end

  test "a forbidden write consumes nothing" do
    {raw, _key} = api_key_fixture(["invoices:read"])
    client = client_fixture()
    before = QuantumBilling.Repo.aggregate(QuantumBilling.Invoices.Invoice, :count)

    conn =
      raw
      |> api_conn()
      |> api_post("/api/v1/invoices", %{
        "client_id" => client.id,
        "items" => [%{"description" => "x"}]
      })

    assert conn.status == 403
    assert QuantumBilling.Repo.aggregate(QuantumBilling.Invoices.Invoice, :count) == before
  end
end
