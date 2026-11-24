defmodule QuantumBilling.Quotations.QuotationItem do
  @moduledoc """
  One quotation line. It has the same fields as `QuantumBilling.Invoices.InvoiceItem`
  and goes through the same changeset, so a line is priced and taxed exactly as
  it would be on an invoice.
  """
  use Ecto.Schema

  alias QuantumBilling.CustomFields
  alias QuantumBilling.Invoices.InvoiceItem

  schema "quotation_items" do
    field :description, :string
    field :hsn_sac, :string
    field :quantity, :decimal, default: Decimal.new(1)
    field :unit, :string, default: "Nos"
    # Minor units of the quotation's currency, as on an invoice line.
    field :rate, :integer, default: 0
    field :tax_rate, :integer, default: 18
    # VAT snapshot of the chosen rate.
    belongs_to :tax_rate_ref, QuantumBilling.TaxRates.TaxRate, foreign_key: :tax_rate_id
    field :tax_rate_bp, :integer
    field :tax_category, :string
    field :tax_name, :string
    field :amount, :integer, default: 0
    field :position, :integer, default: 0

    belongs_to :quotation, QuantumBilling.Quotations.Quotation

    # Values of the "quotation_item" custom fields.
    field :custom_fields, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  The invoice item changeset, applied to a quotation line. `tax` is `:gst` or
  `{:vat, rates_by_id}`. `definitions` are the "quotation_item" custom fields,
  loaded once per quotation by the caller (`nil` loads them here). `currency`
  is the quotation's ISO code.
  """
  def changeset(item, attrs, tax, definitions, currency) do
    definitions = definitions || CustomFields.active_definitions("quotation_item")
    InvoiceItem.changeset(item, attrs, definitions, tax, currency)
  end
end
