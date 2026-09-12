defmodule QuantumBilling.CreditNotes do
  @moduledoc """
  Context module for managing Credit Notes and Debit Notes.
  """
  import Ecto.Query, warn: false
  alias QuantumBilling.Repo
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Invoices.Invoice

  def list_credit_notes do
    CreditNote
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Repo.preload([:invoice, :client])
  end

  def get_credit_note!(id) do
    CreditNote
    |> Repo.get!(id)
    |> Repo.preload([:invoice, :client])
  end

  def create_credit_note_for_invoice(%Invoice{} = invoice, attrs \\ %{}) do
    note_type = Map.get(attrs, "note_type") || Map.get(attrs, :note_type, "Credit")
    prefix = if note_type == "Credit", do: "CN", else: "DN"
    note_number = "#{prefix}-#{invoice.invoice_number}-#{System.unique_integer([:positive])}"

    subtotal =
      Map.get(attrs, "subtotal") ||
        Map.get(attrs, :subtotal, Decimal.new(invoice.taxable_value || 0))

    tax_total =
      Map.get(attrs, "tax_total") ||
        Map.get(
          attrs,
          :tax_total,
          Decimal.new(
            (invoice.cgst_amount || 0) + (invoice.sgst_amount || 0) + (invoice.igst_amount || 0)
          )
        )

    grand_total =
      Map.get(attrs, "grand_total") ||
        Map.get(attrs, :grand_total, Decimal.new(invoice.grand_total || 0))

    reason = Map.get(attrs, "reason") || Map.get(attrs, :reason, "Order modification / refund")

    params = %{
      note_number: note_number,
      note_type: note_type,
      invoice_id: invoice.id,
      client_id: invoice.client_id,
      reason: reason,
      subtotal: subtotal,
      tax_total: tax_total,
      grand_total: grand_total,
      status: "Issued"
    }

    %CreditNote{}
    |> CreditNote.changeset(params)
    |> Repo.insert()
  end
end
