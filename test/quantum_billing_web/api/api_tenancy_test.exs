defmodule QuantumBillingWeb.API.TenancyTest do
  @moduledoc """
  A key reaches its own business's books and no other's.

  Each business keeps its records in a schema of its own, where ids start again
  from 1 — so business 1's invoice 5 and business 2's invoice 5 are different
  invoices with the same id. These tests make the ids collide on purpose.

  Not async: creating a business runs DDL.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import QuantumBilling.ApiFixtures

  alias QuantumBilling.ApiKeys
  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBilling.Businesses
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  setup do
    owner = QuantumBilling.AccountsFixtures.owner_fixture()
    {:ok, other} = Businesses.create(owner, %{"name" => "Firm Two"})
    Repo.put_business(Businesses.default!())

    %{owner: owner, first: Businesses.default!(), other: other}
  end

  defp in_business(business, fun), do: Repo.with_business(business, fun)

  test "the same id in another business is not reachable", %{first: first, other: other} do
    mine = in_business(first, fn -> invoice_fixture(%{client_name: "First Firm Customer"}) end)

    theirs =
      in_business(other, fn ->
        invoice_fixture(%{id: mine.id, client_name: "Second Firm Customer"})
      end)

    assert theirs.id == mine.id

    {raw_first, _} = api_key_fixture(["invoices:read"], %{business: first})
    {raw_other, _} = api_key_fixture(["invoices:read"], %{business: other})

    first_view = raw_first |> api_conn() |> get(~p"/api/v1/invoices/#{mine.id}")
    other_view = raw_other |> api_conn() |> get(~p"/api/v1/invoices/#{mine.id}")

    assert json_response(first_view, 200)["data"]["client"]["name"] == "First Firm Customer"
    assert json_response(other_view, 200)["data"]["client"]["name"] == "Second Firm Customer"
  end

  test "lists hold only the key's business", %{first: first, other: other} do
    in_business(first, fn -> invoice_fixture(%{client_name: "Only In First"}) end)
    in_business(other, fn -> invoice_fixture(%{client_name: "Only In Other"}) end)

    {raw, _} = api_key_fixture(["invoices:read"], %{business: other})
    body = raw |> api_conn() |> get(~p"/api/v1/invoices?per_page=100") |> Map.get(:resp_body)

    assert body =~ "Only In Other"
    refute body =~ "Only In First"
  end

  test "a write lands in the key's business", %{first: first, other: other} do
    client = in_business(other, fn -> client_fixture() end)
    {raw, _} = api_key_fixture(["invoices:write"], %{business: other})

    before_first = in_business(first, fn -> Repo.aggregate(Invoice, :count) end)

    conn =
      raw
      |> api_conn()
      |> api_post(~p"/api/v1/invoices", %{
        "client_id" => client.id,
        "invoice_date" => "2026-10-01",
        "place_of_supply" => "Maharashtra (27)",
        "items" => [%{"description" => "Cross-check", "rate" => 100}]
      })

    id = json_response(conn, 201)["data"]["id"]

    assert in_business(other, fn -> Repo.get(Invoice, id) end).client_id == client.id
    assert in_business(first, fn -> Repo.aggregate(Invoice, :count) end) == before_first

    # And its audit entry is in that business's trail, not the first's.
    assert in_business(other, fn ->
             Repo.exists?(
               from l in QuantumBilling.Audit.AuditLog,
                 where: l.action == "invoice_created" and l.resource_id == ^to_string(id)
             )
           end)
  end

  test "a client id from another business is refused", %{first: first, other: other} do
    foreign = in_business(first, fn -> client_fixture(%{"name" => "First's Customer"}) end)
    {raw, _} = api_key_fixture(["invoices:write"], %{business: other})

    # Nothing in business 2 has this id unless it happens to; make sure it doesn't.
    in_business(other, fn -> Repo.delete_all(QuantumBilling.Clients.Client) end)

    conn =
      raw
      |> api_conn()
      |> api_post(~p"/api/v1/invoices", %{
        "client_id" => foreign.id,
        "invoice_date" => "2026-10-01",
        "place_of_supply" => "Maharashtra (27)",
        "items" => [%{"description" => "x", "rate" => 100}]
      })

    assert %{"client_id" => [_]} = json_response(conn, 422)["error"]["fields"]
  end

  test "the payment link names the key's business", %{other: other} do
    invoice = in_business(other, fn -> invoice_fixture() end)
    {raw, _} = api_key_fixture(["invoices:read", "invoices:payment_links"], %{business: other})

    conn = raw |> api_conn() |> get(~p"/api/v1/invoices/#{invoice.id}")

    assert json_response(conn, 200)["data"]["payment_url"] ==
             url(~p"/p/#{other.slug}/#{invoice.public_token}")
  end

  test "a key stops working when its business is archived", %{owner: owner, other: other} do
    {raw, _} = api_key_fixture(["invoices:read"], %{business: other, owner: owner})
    assert raw |> api_conn() |> get(~p"/api/v1/me") |> Map.get(:status) == 200

    {:ok, _} = Businesses.archive(owner, other)

    assert raw |> api_conn() |> get(~p"/api/v1/me") |> Map.get(:status) == 401
  end

  describe "the keys page" do
    test "an owner sees and revokes only their own business's keys", %{
      conn: conn,
      other: other
    } do
      owner = QuantumBilling.AccountsFixtures.owner_fixture()
      conn = log_in_user(conn, owner)

      {_raw, theirs} = api_key_fixture(["invoices:read"], %{business: other})
      {_raw, mine} = api_key_fixture(["invoices:read"], %{owner: owner})

      {:ok, view, html} = live(conn, ~p"/settings/api-keys")

      assert html =~ mine.prefix
      refute html =~ theirs.prefix

      # A forged event naming the other business's key does nothing to it.
      render_click(view, "revoke", %{"id" => to_string(theirs.id)})

      assert Repo.get!(ApiKey, theirs.id).revoked_at == nil
      assert ApiKeys.get_key(Businesses.default!(), theirs.id) == nil
    end
  end

  describe "the public payment page" do
    test "hears only its own business's invoice, though ids collide", %{
      first: first,
      other: other
    } do
      mine = in_business(first, fn -> invoice_fixture() end)
      theirs = in_business(other, fn -> invoice_fixture(%{id: mine.id}) end)
      assert theirs.id == mine.id

      # Subscribed the way the page subscribes, from business 1.
      in_business(first, fn -> QuantumBilling.Invoices.subscribe(mine.id) end)

      in_business(other, fn -> QuantumBilling.Invoices.broadcast_change(theirs) end)
      refute_receive {:invoice_changed, _}, 50

      in_business(first, fn -> QuantumBilling.Invoices.broadcast_change(mine) end)
      assert_receive {:invoice_changed, %{id: id}}
      assert id == mine.id
    end
  end
end
