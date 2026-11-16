defmodule QuantumBilling.CreditNotesTest do
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Clients.Client

  defp fixture do
    client = Repo.insert!(%Client{name: "Epsilon LLC", email: "epsilon@example.com"})

    invoice1 =
      Repo.insert!(%Invoice{
        invoice_number: "INV-9905",
        invoice_date: ~D[2026-03-01],
        place_of_supply: "Maharashtra",
        company_state: "Maharashtra",
        client_id: client.id,
        client_name: client.name,
        taxable_value: 10000,
        grand_total: 11800
      })

    invoice2 =
      Repo.insert!(%Invoice{
        invoice_number: "INV-9906",
        invoice_date: ~D[2026-03-02],
        place_of_supply: "Maharashtra",
        company_state: "Maharashtra",
        client_id: client.id,
        client_name: client.name,
        taxable_value: 20000,
        grand_total: 23600
      })

    %{client: client, invoice1: invoice1, invoice2: invoice2}
  end

  test "create_credit_note_for_invoice/2 creates consecutive numbers across different invoices" do
    %{invoice1: invoice1, invoice2: invoice2, client: client} = fixture()

    assert {:ok, cn1} =
             CreditNotes.create_credit_note_for_invoice(invoice1, %{
               "note_type" => "Credit",
               "reason" => "Discount applied after issue",
               "grand_total" => Decimal.new("11800.00")
             })

    assert {:ok, cn2} =
             CreditNotes.create_credit_note_for_invoice(invoice2, %{
               "note_type" => "Credit",
               "reason" => "Returned item",
               "grand_total" => Decimal.new("5000.00")
             })

    assert {:ok, dn1} =
             CreditNotes.create_credit_note_for_invoice(invoice1, %{
               "note_type" => "Debit",
               "reason" => "Extra charges",
               "grand_total" => Decimal.new("1000.00")
             })

    assert cn1.note_number == "CN-0001"
    assert cn2.note_number == "CN-0002"
    assert dn1.note_number == "DN-0001"

    assert cn1.note_type == "Credit"
    assert cn1.invoice_id == invoice1.id
    assert cn1.client_id == client.id
    assert %Date{} = cn1.note_date

    assert byte_size(cn1.note_number) <= 16
    assert QuantumBilling.Compliance.document_number_valid?(cn1.note_number)
    assert QuantumBilling.Compliance.document_number_valid?(cn2.note_number)
    assert QuantumBilling.Compliance.document_number_valid?(dn1.note_number)
  end

  test "concurrent creation produces consecutive numbers without collision" do
    %{invoice1: invoice1, invoice2: invoice2} = fixture()
    business = Repo.business()

    task1 =
      Task.async(fn ->
        Repo.with_business(business, fn ->
          CreditNotes.create_credit_note_for_invoice(invoice1, %{"reason" => "Task 1 note"})
        end)
      end)

    task2 =
      Task.async(fn ->
        Repo.with_business(business, fn ->
          CreditNotes.create_credit_note_for_invoice(invoice2, %{"reason" => "Task 2 note"})
        end)
      end)

    assert {:ok, note1} = Task.await(task1)
    assert {:ok, note2} = Task.await(task2)

    numbers = Enum.sort([note1.note_number, note2.note_number])
    assert numbers == ["CN-0001", "CN-0002"]
  end

  test "create_credit_note_for_invoice ignores caller-supplied note_date and enforces current date" do
    %{invoice1: invoice1} = fixture()
    past_date = ~D[2020-01-01]

    assert {:ok, note} =
             CreditNotes.create_credit_note_for_invoice(invoice1, %{
               "reason" => "No backdating test",
               "note_date" => past_date
             })

    assert note.note_date != past_date
  end

  test "CreditNote.changeset validates 16-character limit and statutory document numbering" do
    changeset =
      CreditNotes.CreditNote.changeset(%CreditNotes.CreditNote{}, %{
        note_number: "CN-LONG-EXCEEDING-16-CHARS",
        note_type: "Credit",
        invoice_id: 1,
        client_id: 1,
        grand_total: 100
      })

    refute changeset.valid?
    assert "should be at most 16 character(s)" in errors_on(changeset).note_number
  end
end
