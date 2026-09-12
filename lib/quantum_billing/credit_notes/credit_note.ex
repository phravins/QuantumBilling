defmodule QuantumBilling.CreditNotes.CreditNote do
  @moduledoc """
  Schema for GST Credit and Debit Notes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_notes" do
    field :note_number, :string
    field :note_type, :string, default: "Credit"
    field :reason, :string
    field :subtotal, :decimal, default: Decimal.new("0.0")
    field :tax_total, :decimal, default: Decimal.new("0.0")
    field :grand_total, :decimal, default: Decimal.new("0.0")
    field :status, :string, default: "Issued"

    belongs_to :invoice, QuantumBilling.Invoices.Invoice
    belongs_to :client, QuantumBilling.Clients.Client

    timestamps(type: :utc_datetime)
  end

  @types ~w(Credit Debit)
  @statuses ~w(Issued Cancelled Applied)

  def changeset(credit_note, attrs) do
    credit_note
    |> cast(attrs, [
      :note_number,
      :note_type,
      :invoice_id,
      :client_id,
      :reason,
      :subtotal,
      :tax_total,
      :grand_total,
      :status
    ])
    |> validate_required([:note_number, :note_type, :invoice_id, :client_id, :grand_total])
    |> validate_inclusion(:note_type, @types)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:invoice_id)
    |> foreign_key_constraint(:client_id)
    |> unique_constraint(:note_number)
  end
end
