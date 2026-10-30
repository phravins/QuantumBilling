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

  # {method, path builder, the scope it needs (nil = any key)}
  defp routes(%{invoice: invoice, client: client, bill: bill}) do
    [
      {:get, "/api/v1/me", nil},
      {:get, "/api/v1/invoices", "invoices:read"},
      {:get, "/api/v1/invoices/#{invoice.id}", "invoices:read"},
      {:post, "/api/v1/invoices", "invoices:write"},
      {:get, "/api/v1/clients", "clients:read"},
      {:get, "/api/v1/clients/#{client.id}", "clients:read"},
      {:post, "/api/v1/clients", "clients:write"},
      {:get, "/api/v1/e-way-bills", "e_way_bills:read"},
      {:get, "/api/v1/e-way-bills/#{bill.id}", "e_way_bills:read"}
    ]
  end

  setup do
    invoice = invoice_fixture()
    %{invoice: invoice, client: client_fixture(), bill: e_way_bill_fixture(invoice_fixture())}
  end

  test "each scope opens exactly its own routes", records do
    for scope <- ApiKey.scopes() do
      {raw, _key} = api_key_fixture([scope])

      for {method, path, needed} <- routes(records) do
        conn =
          case method do
            :get -> raw |> api_conn() |> get(path)
            # An empty body: what matters is whether the scope check lets the
            # request reach validation (422) or stops it first (403).
            :post -> raw |> api_conn() |> api_post(path, %{})
          end

        if is_nil(needed) or needed == scope do
          assert conn.status in [200, 422],
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
      |> Enum.map(fn {method, path, _scope} ->
        {method, String.replace(path, ~r{/\d+$}, "/:id")}
      end)
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
