defmodule QuantumBilling.ApiFixtures do
  @moduledoc """
  Keys, records and requests for the external API tests.
  """

  import Phoenix.ConnTest
  import Plug.Conn

  alias QuantumBilling.AccountsFixtures
  alias QuantumBilling.ApiKeys
  alias QuantumBilling.Clients
  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  @endpoint QuantumBillingWeb.Endpoint

  @doc "A live key holding `scopes`. Returns `{raw, key}`."
  def api_key_fixture(scopes, attrs \\ %{}) do
    owner = Map.get_lazy(attrs, :owner, fn -> AccountsFixtures.owner_fixture() end)

    {:ok, %{key: key, raw: raw}} =
      ApiKeys.create_key(
        Map.merge(
          %{"name" => "Integration #{System.unique_integer([:positive])}", "scopes" => scopes},
          Map.delete(attrs, :owner)
        ),
        owner
      )

    {raw, key}
  end

  @doc "A connection carrying `raw` the way a real integration sends it."
  def api_conn(raw) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> raw)
  end

  @doc "A JSON POST with an idempotency key."
  def api_post(conn, path, body, idempotency_key \\ Ecto.UUID.generate()) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(path, Jason.encode!(body))
  end

  def client_fixture(attrs \\ %{}) do
    {:ok, client} =
      Clients.create_client(
        Map.merge(
          %{
            "name" => "V2V Technologies #{System.unique_integer([:positive])}",
            "email" => "billing@v2v.in",
            "phone" => "9876543210",
            "billing_line1" => "123 Business Park",
            "billing_city" => "Mumbai",
            "billing_state" => "Maharashtra (27)",
            "billing_pin" => "400093",
            "client_type" => "Unregistered"
          },
          attrs
        )
      )

    client
  end

  def invoice_fixture(attrs \\ %{}) do
    defaults = %{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra (27)",
      company_state: "Maharashtra (27)",
      client_state: "Karnataka (29)",
      client_name: "Acme India Pvt Ltd",
      client_gstin: "27AAAAA0000A1Z5",
      taxable_value: 100_000,
      grand_total: 118_000,
      public_token: "tok_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }

    Repo.insert!(struct(%Invoice{}, Map.merge(defaults, attrs)))
  end

  def e_way_bill_fixture(invoice \\ nil) do
    {:ok, bill} =
      EWayBills.generate_e_way_bill(invoice || invoice_fixture(), %{
        "distance_km" => "180",
        "vehicle_number" => "MH04CD5678"
      })

    bill
  end
end
