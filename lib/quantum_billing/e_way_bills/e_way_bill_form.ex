defmodule QuantumBilling.EWayBills.EWayBillForm do
  @moduledoc """
  The "Generate New E-Way Bill" form.

  An `embedded_schema`, not a table: the multi-tenant Ecto schema is still
  pending, so nothing is persisted yet. Modelling the form as a changeset
  anyway buys per-field validation and error rendering through the standard
  `<.input field={...}>` plumbing, and gives the future database schema a
  shape to mirror.

  Money is held as whole rupees (integers) so `QuantumBillingWeb.Format.rupees/2`
  can render it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @supply_types ["Outward Supply", "Inward Supply"]

  @sub_types [
    "Supply",
    "Export",
    "Import",
    "Job Work",
    "SKD/CKD",
    "Recipient Not Known",
    "For Own Use",
    "Exhibition or Fairs",
    "Line Sales",
    "Others"
  ]

  @document_types [
    "Tax Invoice",
    "Bill of Supply",
    "Bill of Entry",
    "Delivery Challan",
    "Credit Note",
    "Others"
  ]

  @transaction_types ["Regular", "Bill To - Ship To"]

  @transport_modes ["Road", "Rail", "Air", "Ship"]

  @states [
    "Andhra Pradesh (37)",
    "Assam (18)",
    "Bihar (10)",
    "Chhattisgarh (22)",
    "Delhi (07)",
    "Gujarat (24)",
    "Haryana (06)",
    "Karnataka (29)",
    "Kerala (32)",
    "Madhya Pradesh (23)",
    "Maharashtra (27)",
    "Odisha (21)",
    "Punjab (03)",
    "Rajasthan (08)",
    "Tamil Nadu (33)",
    "Telangana (36)",
    "Uttar Pradesh (09)",
    "West Bengal (19)"
  ]

  # Two letters, one or two digits, up to three letters, four digits: MH01AB1234.
  @vehicle_format ~r/^[A-Z]{2}\d{1,2}[A-Z]{0,3}\d{4}$/
  @gstin_format ~r/^\d{2}[A-Z]{5}\d{4}[A-Z]{1}[A-Z\d]{1}[Z]{1}[A-Z\d]{1}$/

  @required ~w(supply_type sub_type document_type document_no document_date
               transaction_type from_party from_state to_party to_state
               total_goods_value transport_mode vehicle_no from_place to_place)a

  @amount_fields ~w(total_goods_value cgst_value sgst_value igst_value other_amount)a

  @primary_key false
  embedded_schema do
    # 1. Transaction details
    field :supply_type, :string
    field :sub_type, :string
    field :document_type, :string
    field :document_no, :string
    field :document_date, :date
    field :transaction_type, :string

    # 2. Parties details
    field :from_party, :string
    field :from_gstin, :string
    field :from_state, :string
    field :to_party, :string
    field :to_gstin, :string
    field :to_state, :string

    # 3. Item details (whole rupees)
    field :total_goods_value, :integer
    field :cgst_value, :integer, default: 0
    field :sgst_value, :integer, default: 0
    field :igst_value, :integer, default: 0
    field :other_amount, :integer, default: 0

    # 4. Transport details
    field :transport_mode, :string
    field :transporter_name, :string
    field :transporter_id, :string
    field :vehicle_no, :string
    field :from_place, :string
    field :to_place, :string

    # 5. Other details
    field :remarks, :string
  end

  @doc """
  Builds the form changeset.

  Pass `action: :validate` at the call site (or use `validate/2`) to surface
  errors while the user is still typing.
  """
  def changeset(form, attrs \\ %{}) do
    form
    |> cast(attrs, all_fields())
    |> validate_required(@required)
    |> validate_inclusion(:supply_type, @supply_types)
    |> validate_inclusion(:sub_type, @sub_types)
    |> validate_inclusion(:document_type, @document_types)
    |> validate_inclusion(:transaction_type, @transaction_types)
    |> validate_inclusion(:transport_mode, @transport_modes)
    |> validate_inclusion(:from_state, @states)
    |> validate_inclusion(:to_state, @states)
    |> validate_length(:document_no, max: 30)
    |> validate_number(:total_goods_value, greater_than: 0)
    |> validate_amounts()
    |> update_change(:vehicle_no, &String.upcase(String.replace(&1 || "", ~r/\s/, "")))
    |> validate_format(:vehicle_no, @vehicle_format, message: "must look like MH01AB1234")
    |> validate_gstin(:from_gstin)
    |> validate_gstin(:to_gstin)
    |> validate_transporter_id()
    |> validate_length(:remarks, max: 500)
  end

  @doc """
  The changeset used by `phx-change`: same rules, but flagged as `:validate`
  so errors render immediately.
  """
  def validate(form, attrs) do
    form
    |> changeset(attrs)
    |> Map.put(:action, :validate)
  end

  defp validate_amounts(changeset) do
    Enum.reduce(@amount_fields -- [:total_goods_value], changeset, fn field, acc ->
      validate_number(acc, field, greater_than_or_equal_to: 0)
    end)
  end

  defp validate_gstin(changeset, field) do
    validate_format(changeset, field, @gstin_format, message: "is not a valid GSTIN")
  end

  defp validate_transporter_id(changeset) do
    changeset
    |> update_change(:transporter_id, &String.upcase/1)
    |> validate_format(:transporter_id, @gstin_format, message: "must be a 15-character GSTIN")
  end

  @doc """
  Sum of goods, taxes and other charges — what the portal calls the total
  invoice value. Reads straight off the changeset so it stays live while typing.
  """
  def total_invoice_value(%Ecto.Changeset{} = changeset) do
    Enum.reduce(@amount_fields, 0, fn field, acc ->
      acc + (get_field(changeset, field) || 0)
    end)
  end

  def total_invoice_value(%__MODULE__{} = form) do
    Enum.reduce(@amount_fields, 0, fn field, acc ->
      acc + (Map.get(form, field) || 0)
    end)
  end

  @doc """
  Generates a 12-digit e-way bill number, the format the GST portal issues.
  """
  def generate_number do
    Enum.map_join(1..12, fn _ -> Integer.to_string(:rand.uniform(10) - 1) end)
  end

  @doc "Every castable field, in schema order."
  def all_fields, do: __MODULE__.__schema__(:fields)

  def supply_types, do: @supply_types
  def sub_types, do: @sub_types
  def document_types, do: @document_types
  def transaction_types, do: @transaction_types
  def transport_modes, do: @transport_modes
  def states, do: @states
end
