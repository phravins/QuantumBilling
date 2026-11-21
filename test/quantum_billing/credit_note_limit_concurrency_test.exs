defmodule QuantumBilling.CreditNoteLimitConcurrencyTest do
  @moduledoc """
  Credit notes raised at the same moment cannot together credit more than the
  invoice.

  As in `CreditNoteNumberingConcurrencyTest`, the shared sandbox runs the
  tasks' transactions one at a time over one connection: this pins that each
  note reads the limit after the one before it committed, while the
  `FOR UPDATE` locks keep that true across real connections.
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices.Invoice

  test "of three full credits raised at once, exactly one is issued" do
    client = Repo.insert!(%Client{name: "Epsilon LLC", email: "epsilon@example.com"})
    business = Repo.business()

    invoice =
      Repo.insert!(%Invoice{
        invoice_number: "INV-RACE",
        invoice_date: ~D[2026-03-01],
        place_of_supply: "Maharashtra",
        company_state: "Maharashtra",
        client_id: client.id,
        client_name: client.name,
        taxable_value: 1_000_000,
        grand_total: 1_000_000
      })

    results =
      1..3
      |> Task.async_stream(
        fn _n ->
          Repo.put_business(business)

          CreditNotes.create_credit_note_for_invoice(invoice, %{
            "note_type" => "Credit",
            "grand_total" => Decimal.new("10000")
          })
        end,
        max_concurrency: 3,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, _note}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 2

    assert CreditNotes.creditable(invoice) == 0
    assert Repo.get!(Invoice, invoice.id).status == "Credited"
  end
end
