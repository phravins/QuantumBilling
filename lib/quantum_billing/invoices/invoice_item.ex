defmodule QuantumBilling.Invoices.InvoiceItem do
  @moduledoc """
  One invoice line, with its own tax rate (one invoice can mix rates).

  Under GST the rate is a whole-percent slab in `tax_rate`. Under VAT the line
  picks a `tax_rate_id` and snapshots that rate's basis points, category and
  name, so editing the rate later never changes the invoice.

  `rate` is typed in rupees and held in paise; `amount` is computed in paise.
  `quantity` allows three decimal places.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.CustomFields
  alias QuantumBilling.Money
  alias QuantumBilling.Money.Paise
  alias QuantumBilling.Settings.Organization

  @units ["Nos", "Kg", "Ltr", "Mtr", "Box", "Set", "Pcs", "Hrs"]

  schema "invoice_items" do
    field :description, :string
    field :hsn_sac, :string
    field :quantity, :decimal, default: Decimal.new(1)
    field :unit, :string, default: "Nos"
    field :rate, Paise, default: 0
    field :tax_rate, :integer, default: 18
    # VAT snapshot of the chosen rate.
    belongs_to :tax_rate_ref, QuantumBilling.TaxRates.TaxRate, foreign_key: :tax_rate_id
    field :tax_rate_bp, :integer
    field :tax_category, :string
    field :tax_name, :string
    field :amount, :integer, default: 0
    field :position, :integer, default: 0

    belongs_to :invoice, QuantumBilling.Invoices.Invoice

    # Values for the business's own fields. Written only by CustomFields.cast/4.
    field :custom_fields, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @castable ~w(description hsn_sac quantity unit rate tax_rate position)a

  @doc """
  `definitions` are the item fields, loaded once per invoice by the caller.
  `tax` is `:gst`, or `{:vat, rates_by_id}` for a VAT invoice.
  """
  def changeset(item, attrs, definitions \\ nil, tax \\ :gst)

  def changeset(item, attrs, definitions, {:vat, rates}) do
    item
    |> cast(attrs, @castable -- [:tax_rate])
    |> cast(attrs, [:tax_rate_id])
    |> common(attrs, definitions)
    |> snapshot_rate(rates)
  end

  def changeset(item, attrs, definitions, :gst) do
    item
    |> cast(attrs, @castable)
    |> validate_inclusion(:tax_rate, Organization.gst_rates(),
      message: "must be one of the GST slabs: #{Enum.join(Organization.gst_rates(), ", ")}"
    )
    |> common(attrs, definitions)
  end

  defp common(changeset, attrs, definitions) do
    changeset
    |> validate_required([:description])
    |> validate_length(:description, max: 500)
    |> validate_length(:hsn_sac, max: 20)
    |> validate_number(:quantity, greater_than: 0, less_than: 1_000_000_000_000)
    |> validate_quantity_places()
    |> validate_number(:rate, greater_than_or_equal_to: 0)
    |> validate_inclusion(:unit, @units)
    |> CustomFields.cast("invoice_item", attrs, definitions)
    |> put_amount()
  end

  # A newly chosen rate must be active; a line keeps its snapshot otherwise,
  # even when its rate has since been edited or archived.
  defp snapshot_rate(changeset, rates) do
    changeset = put_default_rate(changeset, rates)
    id = get_field(changeset, :tax_rate_id)
    changed? = Map.has_key?(changeset.changes, :tax_rate_id) or is_nil(changeset.data.tax_rate_bp)

    case {id && Map.get(rates, id), changed?} do
      {nil, _changed?} ->
        add_error(changeset, :tax_rate_id, "choose a VAT rate")

      {%{archived_at: archived}, true} when not is_nil(archived) ->
        add_error(changeset, :tax_rate_id, "is archived; choose another rate")

      {rate, true} ->
        change(changeset,
          tax_rate_bp: rate.rate_bp,
          tax_category: rate.category,
          tax_name: rate.name,
          tax_rate: 0
        )

      {_rate, false} ->
        changeset
    end
  end

  # A new line sent without a rate starts on the business's default one.
  defp put_default_rate(changeset, rates) do
    with nil <- changeset.data.id,
         nil <- get_field(changeset, :tax_rate_id),
         %{id: id} <- default_rate(rates) do
      put_change(changeset, :tax_rate_id, id)
    else
      _ -> changeset
    end
  end

  defp default_rate(rates) do
    active =
      rates
      |> Map.values()
      |> Enum.filter(&is_nil(&1.archived_at))
      |> Enum.sort_by(&{&1.position, &1.id})

    Enum.find(active, & &1.is_default) || List.first(active)
  end

  # The column holds three places; a fourth would be silently rounded away.
  defp validate_quantity_places(changeset) do
    validate_change(changeset, :quantity, fn :quantity, quantity ->
      if Decimal.equal?(Decimal.round(quantity, 3), quantity),
        do: [],
        else: [quantity: "can have at most three decimal places"]
    end)
  end

  # Always quantity × rate; never taken from the form.
  defp put_amount(changeset) do
    put_change(
      changeset,
      :amount,
      Money.line_amount(get_field(changeset, :quantity), get_field(changeset, :rate) || 0)
    )
  end

  @doc """
  The line's amount before tax, in paise.
  """
  def amount(%__MODULE__{quantity: quantity, rate: rate}), do: Money.line_amount(quantity, rate)

  def amount(_item), do: 0

  @doc """
  The tax due on this line, at its own rate, in paise.
  """
  def tax(%__MODULE__{tax_rate_bp: rate_bp} = item) when is_integer(rate_bp),
    do: Money.tax_bp(amount(item), QuantumBilling.Tax.effective_bp(item))

  def tax(%__MODULE__{tax_rate: tax_rate} = item) when is_integer(tax_rate) do
    Money.tax(amount(item), tax_rate)
  end

  def tax(_item), do: 0

  def units, do: @units
end
