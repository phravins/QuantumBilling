defmodule QuantumBilling.Invoices.InvoiceItem do
  @moduledoc """
  One line on an invoice.

  Each line carries its own GST rate rather than inheriting an invoice-wide
  one — a single invoice can legitimately mix slabs (18% on services, 5% on
  goods), and the tax has to be worked out per line for that to come out right.

  `rate` is typed in rupees and held in paise (`QuantumBilling.Money.Paise`);
  `amount` is worked out here, also in paise. `quantity` carries up to three
  decimal places, so 2.5 kg or 1.75 hours can be billed.
  """
  use Ecto.Schema

  import Ecto.Changeset

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
    field :amount, :integer, default: 0
    field :position, :integer, default: 0

    belongs_to :invoice, QuantumBilling.Invoices.Invoice

    timestamps(type: :utc_datetime)
  end

  @castable ~w(description hsn_sac quantity unit rate tax_rate position)a

  def changeset(item, attrs) do
    item
    |> cast(attrs, @castable)
    |> validate_required([:description])
    |> validate_length(:description, max: 500)
    |> validate_length(:hsn_sac, max: 20)
    |> validate_number(:quantity, greater_than: 0, less_than: 1_000_000_000_000)
    |> validate_quantity_places()
    |> validate_number(:rate, greater_than_or_equal_to: 0)
    |> validate_inclusion(:unit, @units)
    |> validate_inclusion(:tax_rate, Organization.gst_rates(),
      message: "must be one of the GST slabs: #{Enum.join(Organization.gst_rates(), ", ")}"
    )
    |> put_amount()
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
  def tax(%__MODULE__{tax_rate: tax_rate} = item) when is_integer(tax_rate) do
    Money.tax(amount(item), tax_rate)
  end

  def tax(_item), do: 0

  def units, do: @units
end
