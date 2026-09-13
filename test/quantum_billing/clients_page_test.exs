defmodule QuantumBilling.ClientsPageTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Clients

  defp client_fixture(attrs) do
    {:ok, client} =
      Clients.create_client(
        Map.merge(
          %{
            client_type: "Registered Business",
            name: "Acme Corp",
            phone: "9876543210",
            billing_line1: "Main St",
            billing_city: "Mumbai",
            billing_state: "Maharashtra (27)",
            billing_pin: "400001"
          },
          attrs
        )
      )

    client
  end

  setup do
    client_fixture(%{name: "Acme Corp", email: "hello@acme.test", gstin: "27AAACA1234A1Z5"})

    client_fixture(%{
      name: "Globex Ltd",
      email: "ap@globex.test",
      gstin: "27AAACN1234C1ZP",
      status: "Inactive"
    })

    client_fixture(%{
      name: "Initech",
      email: "billing@initech.test",
      gstin: "27AAACP8542D1ZS",
      outstanding: 5_000
    })

    :ok
  end

  test "pages and counts" do
    result = Clients.page(per_page: 2)

    assert length(result.rows) == 2
    assert result.total == 3
    assert result.total_pages == 2
  end

  test "searches name, GSTIN and email" do
    assert Clients.page(search: "globex").total == 1
    assert Clients.page(search: "27AAACA1234A1Z5").total == 1
    assert Clients.page(search: "initech.test").total == 1
    assert Clients.page(search: "nobody").total == 0
  end

  test "filters by status" do
    assert Clients.page(status: "Inactive").total == 1
    assert Clients.page(status: "All Status").total == 3
  end

  test "sorts alphabetically by default and on request" do
    assert [%{name: "Acme Corp"} | _] = Clients.page().rows
    assert [%{name: "Initech"} | _] = Clients.page(sort_field: :name, sort_dir: :desc).rows
    assert [%{name: "Initech"} | _] = Clients.page(sort_field: :outstanding, sort_dir: :desc).rows
  end

  test "an unknown sort field falls back to the default ordering" do
    assert [%{name: "Acme Corp"} | _] = Clients.page(sort_field: :"; DROP TABLE clients").rows
  end

  test "clamps the page and the page size" do
    assert Clients.page(page: 99, per_page: 2).page == 2
    assert Clients.page(per_page: 5_000).per_page == 200
  end
end
