defmodule QuantumBilling.Invoices.InvoiceItem do
  @moduledoc """
  One line on an invoice.

  Each line carries its own GST rate rather than inheriting an invoice-wide
  one — a single invoice can legitimately mix slabs (18% on services, 5% on
  goods), and the tax has to be worked out per line for that to come out right.

  Money is whole rupees (integers), as everywhere else in this application.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.Settings.Organization

  @units ["Nos", "Kg", "Ltr", "Mtr", "Box", "Set", "Pcs", "Hrs"]

  schema "invoice_items" do
    field :description, :string
    field :hsn_sac, :string
    field :quantity, :integer, default: 1
    field :unit, :string, default: "Nos"
    field :rate, :integer, default: 0
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
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:rate, greater_than_or_equal_to: 0)
    |> validate_inclusion(:unit, @units)
    |> validate_inclusion(:tax_rate, Organization.gst_rates(),
      message: "must be one of the GST slabs: #{Enum.join(Organization.gst_rates(), ", ")}"
    )
    |> put_amount()
  end

  # Derived, never taken from the form: the amount column must always equal
  # quantity × rate, and letting it be submitted would allow the two to
  # disagree.
  defp put_amount(changeset) do
    quantity = get_field(changeset, :quantity) || 0
    rate = get_field(changeset, :rate) || 0

    put_change(changeset, :amount, quantity * rate)
  end

  @doc """
  The line's amount before tax.
  """
  def amount(%__MODULE__{quantity: quantity, rate: rate})
      when is_integer(quantity) and is_integer(rate),
      do: quantity * rate

  def amount(_item), do: 0

  @doc """
  The tax due on this line, at its own rate.
  """
  def tax(%__MODULE__{tax_rate: tax_rate} = item) when is_integer(tax_rate) do
    div(amount(item) * tax_rate, 100)
  end

  def tax(_item), do: 0

  def units, do: @units
end
