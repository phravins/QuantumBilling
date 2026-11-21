defmodule QuantumBilling.CreditNotesTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Compliance
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Settings

  defp invoice(number \\ "INV-#{System.unique_integer([:positive])}") do
    client = Repo.insert!(%Client{name: "Epsilon LLC", email: "epsilon@example.com"})

    Repo.insert!(%Invoice{
      invoice_number: number,
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_id: client.id,
      client_name: client.name,
      taxable_value: 10000,
      grand_total: 11800
    })
  end

  defp raise_note(invoice, type \\ "Credit") do
    {:ok, note} = CreditNotes.create_credit_note_for_invoice(invoice, %{"note_type" => type})
    note
  end

  test "create_credit_note_for_invoice/2 creates a Credit Note linked to invoice" do
    invoice = invoice("INV-9905")

    assert {:ok, cn} =
             CreditNotes.create_credit_note_for_invoice(invoice, %{
               "note_type" => "Credit",
               "reason" => "Discount applied after issue",
               "grand_total" => Decimal.new("118.00")
             })

    assert cn.note_number == "CN-0001"
    assert cn.note_type == "Credit"
    assert cn.invoice_id == invoice.id
    assert cn.client_id == invoice.client_id
  end

  describe "note numbers (Rule 53)" do
    test "run consecutively across invoices" do
      assert raise_note(invoice()).note_number == "CN-0001"
      assert raise_note(invoice()).note_number == "CN-0002"
      assert Settings.get_organization().credit_note_next_number == 3
    end

    test "debit notes run their own series" do
      assert raise_note(invoice(), "Credit").note_number == "CN-0001"
      assert raise_note(invoice(), "Debit").note_number == "DN-0001"
      assert raise_note(invoice(), "Debit").note_number == "DN-0002"
      assert raise_note(invoice(), "Credit").note_number == "CN-0002"
    end

    test "follow the business's prefix, next number and padding" do
      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{
            "credit_note_prefix" => "CR/26",
            "credit_note_next_number" => "41",
            "invoice_number_padding" => "3"
          },
          :invoice
        )

      assert raise_note(invoice()).note_number == "CR/26-041"
    end

    test "are refused, not issued, if they would break the GST format" do
      # A stored prefix older than the settings check.
      Settings.ensure_organization()
      |> Ecto.Changeset.change(credit_note_prefix: "QUANTUMBILLS")
      |> Repo.update!()

      assert {:error, changeset} = CreditNotes.create_credit_note_for_invoice(invoice(), %{})
      assert %{note_number: [_]} = errors_on(changeset)
      # The number is not used up by a note that was never issued.
      assert Settings.get_organization().credit_note_next_number == 1
    end

    test "cannot be set from the request" do
      {:ok, note} =
        CreditNotes.create_credit_note_for_invoice(invoice(), %{
          "note_number" => "MINE-1",
          "note_date" => "2020-01-01"
        })

      assert note.note_number == "CN-0001"
      assert note.note_date == Compliance.local_date()
    end
  end

  test "a note is dated today where the business is" do
    note = raise_note(invoice())

    assert note.note_date == Compliance.local_date(DateTime.utc_now(), "Asia/Kolkata")
  end

  test "Compliance.local_date/2 is the IST date just after midnight IST" do
    # 00:30 IST on 1 December is still 30 November in UTC.
    assert Compliance.local_date(~U[2026-11-30 19:00:00Z], "Asia/Kolkata") == ~D[2026-12-01]
    assert Compliance.local_date(~U[2026-11-30 18:29:59Z], "Asia/Kolkata") == ~D[2026-11-30]
  end

  describe "Compliance.document_number_valid?/1" do
    test "accepts up to 16 letters, digits, - and /" do
      assert Compliance.document_number_valid?("CN-0001")
      assert Compliance.document_number_valid?("A/26-27/0000001")
      assert Compliance.document_number_valid?(String.duplicate("A", 16))
    end

    test "refuses 17 characters, other characters, and a bad first character" do
      refute Compliance.document_number_valid?(String.duplicate("A", 17))
      refute Compliance.document_number_valid?("QUANTUMBILLS-0001")
      refute Compliance.document_number_valid?("CN 0001")
      refute Compliance.document_number_valid?("CN_0001")
      refute Compliance.document_number_valid?("-CN-0001")
      refute Compliance.document_number_valid?("/CN-0001")
      refute Compliance.document_number_valid?("0CN-0001")
      refute Compliance.document_number_valid?("")
      refute Compliance.document_number_valid?(nil)
    end
  end
end
