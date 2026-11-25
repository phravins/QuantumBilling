defmodule QuantumBilling.CreditNoteLimitsTest do
  @moduledoc """
  A credit note can be at most what is left to credit on its invoice, a note
  cannot be raised on a cancelled or binned invoice, and an unpaid invoice
  credited in full becomes "Credited".
  """
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments

  # ₹10,000 with ₹1,800 GST on top, so ₹11,800 in all.
  defp invoice(attrs \\ %{}) do
    client = Repo.insert!(%Client{name: "Epsilon LLC", email: "epsilon@example.com"})

    Repo.insert!(
      struct(
        %Invoice{
          invoice_number: "INV-#{System.unique_integer([:positive])}",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_id: client.id,
          client_name: client.name,
          taxable_value: 1_000_000,
          cgst_amount: 90_000,
          sgst_amount: 90_000,
          grand_total: 1_180_000
        },
        attrs
      )
    )
  end

  defp credit(invoice, rupees, type \\ "Credit") do
    CreditNotes.create_credit_note_for_invoice(invoice, %{
      "note_type" => type,
      "grand_total" => Decimal.new(rupees)
    })
  end

  defp status(invoice), do: Repo.get!(Invoice, invoice.id).status

  defp errors_on_note({:error, %Ecto.Changeset{} = changeset}), do: errors_on(changeset)

  describe "the limit" do
    test "a credit note over the invoice's total is refused" do
      invoice = invoice()

      result = credit(invoice, "11800.01")

      assert %{grand_total: [message]} = errors_on_note(result)
      assert message =~ "11800.00 left to credit"
      assert CreditNotes.creditable(invoice) == 1_180_000
    end

    test "counts the credit notes already raised" do
      invoice =
        invoice(%{
          taxable_value: 1_000_000,
          cgst_amount: 0,
          sgst_amount: 0,
          grand_total: 1_000_000
        })

      assert {:ok, _first} = credit(invoice, "7000")
      assert %{grand_total: [_]} = errors_on_note(credit(invoice, "7000"))

      assert CreditNotes.creditable(invoice) == 300_000
      assert {:ok, _rest} = credit(invoice, "3000")
      assert CreditNotes.creditable(invoice) == 0
    end

    test "a debit note raises it, and has no limit of its own" do
      invoice = invoice()

      assert {:ok, _debit} = credit(invoice, "50000", "Debit")
      assert CreditNotes.creditable(invoice) == 1_180_000 + 5_000_000

      assert {:ok, _credit} = credit(invoice, "61800")
    end

    test "a total left out defaults to what is left to credit" do
      invoice = invoice()
      {:ok, _part} = credit(invoice, "1800")

      assert {:ok, note} =
               CreditNotes.create_credit_note_for_invoice(invoice, %{"note_type" => "Credit"})

      assert note.grand_total == 1_000_000
      assert CreditNotes.creditable(invoice) == 0
    end

    test "a total-only note takes its taxable value and tax in the invoice's proportion" do
      invoice = invoice()

      {:ok, note} = credit(invoice, "1180")

      assert note.subtotal == 100_000
      assert note.tax_total == 18_000
      assert note.subtotal + note.tax_total == note.grand_total
    end

    test "a given taxable value leaves the tax as the rest of the total" do
      invoice = invoice()

      {:ok, note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "note_type" => "Credit",
          "grand_total" => Decimal.new("500"),
          "subtotal" => Decimal.new("450")
        })

      assert {note.subtotal, note.tax_total} == {45_000, 5_000}
    end
  end

  describe "closed invoices" do
    test "a cancelled invoice takes no note" do
      invoice = invoice(%{status: "Cancelled"})

      assert %{invoice_id: ["is cancelled, so no note can be issued"]} =
               errors_on_note(credit(invoice, "100"))

      assert %{invoice_id: [_]} = errors_on_note(credit(invoice, "100", "Debit"))
    end

    test "a copy loaded before the invoice was cancelled is refused too" do
      invoice = invoice()
      Repo.update!(Ecto.Changeset.change(invoice, status: "Cancelled"))

      assert %{invoice_id: [_]} = errors_on_note(credit(invoice, "100"))
      assert CreditNotes.list_credit_notes() == []
    end

    test "a binned invoice takes no note" do
      invoice = invoice(%{deleted_at: DateTime.utc_now(:second)})

      assert %{invoice_id: ["is in the Bin, so no note can be issued"]} =
               errors_on_note(credit(invoice, "100"))
    end
  end

  describe "the Credited status" do
    test "a full credit marks a Draft invoice Credited" do
      invoice = invoice()

      {:ok, _} = credit(invoice, "11800")

      assert status(invoice) == "Credited"
    end

    test "a partial credit leaves the invoice owed" do
      invoice = invoice()

      {:ok, _} = credit(invoice, "11799.99")

      assert status(invoice) == "Draft"
    end

    test "a full credit marks an e-invoiced invoice Credited" do
      invoice = invoice(%{status: "E-Invoice Generated", irn: "irn-123"})

      {:ok, _} = credit(invoice, "11800")

      assert status(invoice) == "Credited"
    end

    test "a fully credited paid invoice stays Paid" do
      invoice = invoice(%{status: "Paid"})

      {:ok, _} = credit(invoice, "11800")

      assert status(invoice) == "Paid"
    end

    test "a debit note makes a credited invoice owed again" do
      invoice = invoice()
      {:ok, _} = credit(invoice, "11800")

      {:ok, _} = credit(invoice, "500", "Debit")

      assert status(invoice) == "Draft"
      assert CreditNotes.creditable(invoice) == 50_000
    end

    test "a reopened invoice with an IRN goes back to E-Invoice Generated" do
      invoice = invoice(%{status: "E-Invoice Generated", irn: "irn-456"})
      {:ok, _} = credit(invoice, "11800")

      {:ok, _} = credit(invoice, "500", "Debit")

      assert status(invoice) == "E-Invoice Generated"
    end

    test "a credited invoice cannot be paid or given a payment link" do
      invoice = invoice(%{status: "Credited"})

      refute Payments.open_for_payment?(invoice)
      assert {:error, :credited} = Payments.generate_payment_link(invoice)
      assert {:error, :credited} = Payments.record_payment(invoice, "NEFT-1", 1_180_000)
      assert {:error, :invoice_credited} = Payments.reconcile_payment(invoice, "pay_1")
    end

    test "a copy loaded before the invoice was credited is not marked paid" do
      invoice = invoice()
      {:ok, _} = credit(invoice, "11800")

      assert {:error, :invoice_credited} = Payments.reconcile_payment(invoice, "pay_stale")
      assert status(invoice) == "Credited"
    end

    test "a credited invoice cannot be cancelled" do
      invoice = invoice(%{status: "Credited"})

      assert {:error, :credited} = Invoices.cancel_invoice(invoice, "Duplicate")
    end

    test "a credited invoice owes nothing" do
      invoice = invoice()
      {:ok, _} = credit(invoice, "11800")

      assert Invoices.totals().outstanding == 0
      assert QuantumBilling.Clients.outstanding(Repo.get!(Client, invoice.client_id)) == 0
    end
  end
end
