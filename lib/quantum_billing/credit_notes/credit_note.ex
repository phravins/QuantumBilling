defmodule QuantumBilling.CreditNotes.CreditNote do
  @moduledoc """
  Schema for Credit and Debit Notes, under the regime of their invoice.

  Amounts are typed in major units of the invoice's currency and held in its
  minor units, like invoice rates. A VAT note carries a per-rate
  `tax_breakdown` scaled from its invoice's.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias QuantumBilling.CustomFields
  alias QuantumBilling.Money

  schema "credit_notes" do
    # Both set by `CreditNotes` from the business's series and timezone; never cast.
    field :note_number, :string
    field :note_date, :date
    field :note_type, :string, default: "Credit"
    field :reason, :string
    # Minor units of the invoice's currency; parsed by Money.cast_amount/4.
    field :subtotal, :integer, default: 0
    field :tax_total, :integer, default: 0
    field :grand_total, :integer, default: 0
    field :status, :string, default: "Issued"
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

  @doc """
  `trusted` carries `note_number` and `note_date`, which the caller takes from
  the business's series and timezone; they are never read from `attrs`. Its
  `currency` is the invoice's ISO code, which reads the amounts, and its
  `creditable`, in minor units, is the most a credit note on the invoice may be.
  """
  def changeset(credit_note, attrs, trusted \\ %{}) do
    currency = Map.get(trusted, :currency)

    credit_note
    |> cast(attrs, [:note_type, :invoice_id, :client_id, :reason, :status])
    |> Money.cast_amount(attrs, :subtotal, currency)
    |> Money.cast_amount(attrs, :tax_total, currency)
    |> Money.cast_amount(attrs, :grand_total, currency)
    |> change(Map.take(trusted, [:note_number, :note_date]))
    |> validate_required([
      :note_number,
      :note_date,
      :note_type,
      :invoice_id,
      :client_id,
      :grand_total
    ])
    # The last guard before GSTR-1, whose portal refuses anything else.
    |> validate_change(:note_number, fn :note_number, number ->
      if QuantumBilling.Compliance.document_number_valid?(number),
        do: [],
        else: [note_number: "must be at most 16 letters, numbers, - or /"]
    end)
    |> validate_number(:grand_total, greater_than_or_equal_to: 0)
    |> validate_creditable(Map.get(trusted, :creditable), currency)
    |> validate_inclusion(:note_type, @types)
    |> validate_inclusion(:status, @statuses)
    |> CustomFields.cast("credit_note", attrs, nil, currency)
    |> foreign_key_constraint(:invoice_id)
    |> foreign_key_constraint(:client_id)
    |> unique_constraint(:note_number)
  end

  # A debit note adds to the invoice, so only a credit note has a ceiling.
  defp validate_creditable(changeset, nil, _currency), do: changeset

  defp validate_creditable(changeset, creditable, currency) do
    if get_field(changeset, :note_type) == "Credit" do
      validate_number(changeset, :grand_total,
        less_than_or_equal_to: creditable,
        message:
          "is more than the #{Money.to_input(creditable, currency)} left to credit on this invoice"
      )
    else
      changeset
    end
  end
end
