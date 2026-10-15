defmodule QuantumBilling.ClientsPageTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Clients
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices.Invoice

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

  defp invoice_fixture(client, attrs) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_number: "INV-#{System.unique_integer([:positive])}",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_id: client.id,
          client_name: client.name,
          taxable_value: 10_000,
          grand_total: 10_000,
          status: "Draft"
        },
        attrs
      )
    )
  end

  defp outstanding_by_name(rows), do: Map.new(rows, &{&1.name, &1.outstanding})

  setup do
    client_fixture(%{name: "Acme Corp", email: "hello@acme.test", gstin: "27AAACA1234A1Z5"})

    client_fixture(%{
      name: "Globex Ltd",
      email: "ap@globex.test",
      gstin: "27AAACN1234C1ZP",
      status: "Inactive"
    })

    initech =
      client_fixture(%{
        name: "Initech",
        email: "billing@initech.test",
        gstin: "27AAACP8542D1ZS"
      })

    invoice_fixture(initech, %{grand_total: 5_000})

    %{initech: initech}
  end

  test "pages without counting" do
    first = Clients.page(per_page: 2)
    assert length(first.rows) == 2
    assert first.has_next?

    last = Clients.page(page: 2, per_page: 2)
    assert length(last.rows) == 1
    refute last.has_next?
  end

  test "searches name, GSTIN and email" do
    assert length(Clients.page(search: "globex").rows) == 1
    assert length(Clients.page(search: "27AAACA1234A1Z5").rows) == 1
    assert length(Clients.page(search: "initech.test").rows) == 1
    assert length(Clients.page(search: "nobody").rows) == 0
  end

  test "filters by status" do
    assert length(Clients.page(status: "Inactive").rows) == 1
    assert length(Clients.page(status: "All Status").rows) == 3
  end

  test "sorts alphabetically by default and on request" do
    assert [%{name: "Acme Corp"} | _] = Clients.page().rows
    assert [%{name: "Initech"} | _] = Clients.page(sort_field: :name, sort_dir: :desc).rows
  end

  describe "outstanding" do
    test "is what each client still owes, net of its notes", %{initech: initech} do
      acme = Clients.get_client_by_name("Acme Corp")

      credited = invoice_fixture(acme, %{grand_total: 8_000})
      debited = invoice_fixture(acme, %{grand_total: 2_000})
      invoice_fixture(acme, %{grand_total: 50_000, status: "Paid"})
      invoice_fixture(acme, %{grand_total: 60_000, status: "Cancelled"})
      invoice_fixture(acme, %{grand_total: 70_000, deleted_at: ~U[2026-03-02 00:00:00Z]})

      {:ok, _} =
        CreditNotes.create_credit_note_for_invoice(credited, %{
          "note_type" => "Credit",
          "grand_total" => Decimal.new("3000")
        })

      {:ok, _} =
        CreditNotes.create_credit_note_for_invoice(debited, %{
          "note_type" => "Debit",
          "grand_total" => Decimal.new("500.40")
        })

      # 8,000 - 3,000 + 2,000 + 500 (rounded); paid, cancelled and binned invoices owe nothing.
      assert %{"Acme Corp" => 7_500, "Globex Ltd" => 0, "Initech" => 5_000} =
               outstanding_by_name(Clients.page().rows)

      assert Clients.outstanding(acme) == 7_500
      assert Clients.outstanding(initech) == 5_000
    end

    test "is never negative" do
      globex = Clients.get_client_by_name("Globex Ltd")
      invoice = invoice_fixture(globex, %{grand_total: 1_000})

      {:ok, _} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "note_type" => "Credit",
          "grand_total" => Decimal.new("4000")
        })

      assert Clients.outstanding(globex) == 0
      assert %{"Globex Ltd" => 0} = outstanding_by_name(Clients.page().rows)
    end

    test "sorts the whole directory, not just the page" do
      acme = Clients.get_client_by_name("Acme Corp")
      invoice_fixture(acme, %{grand_total: 900})

      assert ["Initech", "Acme Corp", "Globex Ltd"] =
               Clients.page(sort_field: :outstanding, sort_dir: :desc)
               |> Map.fetch!(:rows)
               |> Enum.map(& &1.name)

      assert [%{name: "Globex Ltd", outstanding: 0}] =
               Clients.page(sort_field: :outstanding, sort_dir: :asc, per_page: 1).rows
    end
  end

  test "an unknown sort field falls back to the default ordering" do
    assert [%{name: "Acme Corp"} | _] = Clients.page(sort_field: :"; DROP TABLE clients").rows
  end

  test "clamps the page and the page size" do
    assert Clients.page(page: 99, per_page: 2).page == 2
    assert Clients.page(per_page: 5_000).per_page == 200
  end
end
