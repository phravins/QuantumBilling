defmodule QuantumBilling.CreditNoteNumberingConcurrencyTest do
  @moduledoc """
  Notes raised at the same moment still get one consecutive series (Rule 53).

  The sandbox is shared here, so the tasks run their transactions one at a
  time over one connection: this pins that concurrent callers get distinct,
  gapless numbers, while the `FOR UPDATE` lock is what keeps that true across
  real connections.
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Settings

  test "ten notes raised at once are numbered CN-0001 to CN-0010" do
    client = Repo.insert!(%Client{name: "Epsilon LLC", email: "epsilon@example.com"})
    business = Repo.business()

    invoices =
      for n <- 1..10 do
        Repo.insert!(%Invoice{
          invoice_number: "INV-#{9000 + n}",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_id: client.id,
          client_name: client.name,
          taxable_value: 10000,
          grand_total: 11800
        })
      end

    numbers =
      invoices
      |> Task.async_stream(
        fn invoice ->
          Repo.put_business(business)
          {:ok, note} = CreditNotes.create_credit_note_for_invoice(invoice, %{})
          note.note_number
        end,
        max_concurrency: 10,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, number} -> number end)

    expected = for n <- 1..10, do: "CN-" <> String.pad_leading("#{n}", 4, "0")

    assert Enum.sort(numbers) == expected
    assert Settings.get_organization().credit_note_next_number == 11
  end
end
