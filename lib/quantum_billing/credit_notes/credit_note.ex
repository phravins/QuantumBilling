defmodule QuantumBilling.CreditNotes.CreditNote do
  @moduledoc """
  Schema for Credit and Debit Notes, under the regime of their invoice.

  Amounts are cast from rupees and held in paise, like invoice rates. A VAT
  note carries a per-rate `tax_breakdown` scaled from its invoice's.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias QuantumBilling.CustomFields
  alias QuantumBilling.Money.Paise

  schema "credit_notes" do
    field :note_number, :string
    field :note_type, :string, default: "Credit"
    field :reason, :string
    field :subtotal, Paise, default: 0
    field :tax_total, Paise, default: 0
    field :grand_total, Paise, default: 0
    field :status, :string, default: "Issued"
    field :note_date, :date
    # Copied from the invoice; never cast from params.
    field :tax_regime, :string, default: "gst"
    field :tax_breakdown, {:array, :map}, default: []

    belongs_to :invoice, QuantumBilling.Invoices.Invoice
    belongs_to :client, QuantumBilling.Clients.Client

    # Values for the business's own fields. Written only by CustomFields.cast/4.
    field :custom_fields, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @types ~w(Credit Debit)
  @statuses ~w(Issued Cancelled Applied)

  def changeset(credit_note, attrs) do
    credit_note
    |> cast(attrs, [
      :note_number,
      :note_type,
      :note_date,
      :invoice_id,
      :client_id,
      :reason,
      :subtotal,
      :tax_total,
      :grand_total,
      :status
    ])
    |> validate_required([:note_number, :note_type, :note_date, :invoice_id, :client_id, :grand_total])
    |> validate_length(:note_number, max: 16)
    |> validate_document_number()
    |> validate_number(:grand_total, greater_than_or_equal_to: 0)
    |> validate_inclusion(:note_type, @types)
    |> validate_inclusion(:status, @statuses)
    |> CustomFields.cast("credit_note", attrs)
    |> foreign_key_constraint(:invoice_id)
    |> foreign_key_constraint(:client_id)
    |> unique_constraint(:note_number)
  end

  defp validate_document_number(changeset) do
    validate_change(changeset, :note_number, fn :note_number, number ->
      if QuantumBilling.Compliance.document_number_valid?(number) do
        []
      else
        [note_number: "must be at most 16 characters and comply with statutory numbering rules"]
      end
    end)
  end
end
