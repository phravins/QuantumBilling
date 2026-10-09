defmodule QuantumBilling.Clients.Client do
  @moduledoc """
  A customer the tenant invoices.

  Several validations here are GST rules rather than generic form checks:

    * a GSTIN is only *required* for the registration types that have one —
      an unregistered dealer or a walk-in consumer has none, and B2C invoicing
      needs them
    * the PAN is embedded in the GSTIN, so the two must agree
    * a GSTIN opens with the state code of the state it was registered in, so a
      `27…` GSTIN against a Karnataka address is a data error

  Money is whole rupees (integers) throughout.

  ## The Bin

  Deleting a client sets `deleted_at` and leaves the row where it is, so the
  invoices raised for it still point at it and a restore is exact. `kept/1` is
  the filter every read goes through.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.GST

  @gstin_types ["Registered Business", "Composition Scheme", "SEZ Unit"]

  @client_types @gstin_types ++ ["Unregistered", "Overseas", "Consumer"]

  @business_types [
    "Proprietorship",
    "Partnership",
    "LLP",
    "Private Limited",
    "Public Limited",
    "HUF",
    "Trust",
    "Society"
  ]

  @categories ["Customer", "Supplier", "Both"]

  @country_codes ["+91", "+1", "+44", "+61", "+65", "+971"]

  @statuses ["Active", "Inactive", "Blocked"]

  schema "clients" do
    field :client_type, :string, default: "Registered Business"
    field :name, :string
    field :display_name, :string
    field :gstin, :string
    field :pan, :string
    field :legal_name, :string
    field :business_type, :string
    field :category, :string

    field :phone_country_code, :string, default: "+91"
    field :phone, :string
    field :email, :string

    field :billing_line1, :string
    field :billing_line2, :string
    field :billing_city, :string
    field :billing_state, :string
    field :billing_pin, :string

    field :shipping_same_as_billing, :boolean, default: true
    field :shipping_line1, :string
    field :shipping_line2, :string
    field :shipping_city, :string
    field :shipping_state, :string
    field :shipping_pin, :string

    field :credit_limit, :integer, default: 0
    field :payment_terms_days, :integer, default: 30
    field :opening_balance, :integer, default: 0
    field :notes, :string

    field :status, :string, default: "Active"
    field :outstanding, :integer, default: 0

    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @castable ~w(client_type name display_name gstin pan legal_name business_type category
               phone_country_code phone email
               billing_line1 billing_line2 billing_city billing_state billing_pin
               shipping_same_as_billing shipping_line1 shipping_line2 shipping_city
               shipping_state shipping_pin
               credit_limit payment_terms_days opening_balance notes status)a

  @doc """
  Builds a client changeset.
  """
  def changeset(client, attrs) do
    client
    |> cast(attrs, @castable)
    |> validate_required([:client_type, :name, :phone])
    |> validate_length(:name, max: 160)
    |> validate_inclusion(:client_type, @client_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_optional_inclusion(:business_type, @business_types)
    |> validate_optional_inclusion(:category, @categories)
    |> validate_inclusion(:phone_country_code, @country_codes)
    |> validate_gstin()
    |> validate_pan_field()
    |> GST.validate_gstin_matches_pan(:gstin, :pan)
    |> validate_gstin_state()
    |> validate_email()
    |> validate_phone()
    |> validate_billing_address()
    |> validate_shipping_address()
    |> copy_billing_to_shipping()
    |> validate_number(:credit_limit, greater_than_or_equal_to: 0)
    |> validate_number(:opening_balance, greater_than_or_equal_to: 0)
    |> validate_number(:payment_terms_days,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 365
    )
    |> validate_length(:notes, max: 2000)
    |> unique_constraint(:gstin,
      name: :clients_gstin_unique,
      message: "is already registered to another client"
    )
  end

  @doc "Narrows `query` to clients that are not in the Bin."
  def kept(query \\ __MODULE__) do
    from c in query, where: is_nil(c.deleted_at)
  end

  @doc "Narrows `query` to clients that are in the Bin."
  def binned(query \\ __MODULE__) do
    from c in query, where: not is_nil(c.deleted_at)
  end

  @doc "Moves a client to the Bin."
  def bin_changeset(client), do: change(client, deleted_at: DateTime.utc_now(:second))

  @doc """
  Takes a client back out of the Bin.

  A binned client gives up its GSTIN — the unique index only covers clients
  that are live — so another client may have been registered under it since.
  The constraint is declared here so that coming back into a taken GSTIN is an
  error on the changeset rather than a raise.
  """
  def restore_changeset(client) do
    client
    |> change(deleted_at: nil)
    |> unique_constraint(:gstin,
      name: :clients_gstin_unique,
      message: "is already registered to another client"
    )
  end

  @doc """
  Whether a client of this type must supply a GSTIN.
  """
  def gstin_required?(client_type), do: client_type in @gstin_types

  defp validate_gstin(changeset) do
    changeset = GST.validate_gstin(changeset, :gstin)

    if gstin_required?(get_field(changeset, :client_type)) do
      validate_required(changeset, [:gstin],
        message: "is required for a #{get_field(changeset, :client_type)}"
      )
    else
      changeset
    end
  end

  defp validate_pan_field(changeset) do
    case get_field(changeset, :pan) do
      blank when blank in [nil, ""] -> changeset
      _present -> GST.validate_pan(changeset, :pan)
    end
  end

  # A GSTIN's first two digits are the state code and must match the state.
  defp validate_gstin_state(changeset) do
    gstin = get_field(changeset, :gstin)
    state = get_field(changeset, :billing_state)

    with true <- GST.valid_gstin?(gstin),
         code when is_binary(code) <- GST.state_code(state),
         false <- String.starts_with?(gstin, code) do
      add_error(
        changeset,
        :billing_state,
        "does not match the GSTIN's state code (#{binary_part(gstin, 0, 2)})"
      )
    else
      _ -> changeset
    end
  end

  defp validate_email(changeset) do
    case get_field(changeset, :email) do
      blank when blank in [nil, ""] ->
        changeset

      _present ->
        changeset
        |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
          message: "must have the @ sign and no spaces"
        )
        |> validate_length(:email, max: 160)
    end
  end

  defp validate_phone(changeset) do
    changeset = update_change(changeset, :phone, &strip_spaces/1)

    case get_field(changeset, :phone_country_code) do
      "+91" ->
        validate_format(changeset, :phone, ~r/^\d{10}$/, message: "must be 10 digits")

      _other ->
        validate_format(changeset, :phone, ~r/^\d{6,15}$/, message: "must be 6 to 15 digits")
    end
  end

  defp validate_billing_address(changeset) do
    changeset
    |> validate_required([:billing_line1, :billing_city, :billing_state, :billing_pin],
      message: "can't be blank"
    )
    |> validate_inclusion(:billing_state, EWayBillForm.states())
    |> validate_pin(:billing_pin)
  end

  # Skipped while "same as billing" is on: the shipping fields are hidden.
  defp validate_shipping_address(changeset) do
    if get_field(changeset, :shipping_same_as_billing) do
      changeset
    else
      changeset
      |> validate_pin(:shipping_pin)
      |> validate_optional_inclusion(:shipping_state, EWayBillForm.states())
    end
  end

  defp validate_pin(changeset, field) do
    case get_field(changeset, field) do
      blank when blank in [nil, ""] ->
        changeset

      _present ->
        changeset
        |> update_change(field, &strip_spaces/1)
        |> validate_format(field, ~r/^\d{6}$/, message: "must be 6 digits")
    end
  end

  defp copy_billing_to_shipping(changeset) do
    if get_field(changeset, :shipping_same_as_billing) do
      changeset
      |> put_change(:shipping_line1, get_field(changeset, :billing_line1))
      |> put_change(:shipping_line2, get_field(changeset, :billing_line2))
      |> put_change(:shipping_city, get_field(changeset, :billing_city))
      |> put_change(:shipping_state, get_field(changeset, :billing_state))
      |> put_change(:shipping_pin, get_field(changeset, :billing_pin))
    else
      changeset
    end
  end

  # validate_inclusion rejects blanks, but these dropdowns are optional.
  defp validate_optional_inclusion(changeset, field, allowed) do
    case get_field(changeset, field) do
      blank when blank in [nil, ""] -> changeset
      _present -> validate_inclusion(changeset, field, allowed)
    end
  end

  defp strip_spaces(nil), do: nil
  defp strip_spaces(value) when is_binary(value), do: String.replace(value, ~r/[\s-]/, "")
  defp strip_spaces(value), do: value

  def client_types, do: @client_types
  def gstin_types, do: @gstin_types
  def business_types, do: @business_types
  def categories, do: @categories
  def country_codes, do: @country_codes
  def statuses, do: @statuses
end
