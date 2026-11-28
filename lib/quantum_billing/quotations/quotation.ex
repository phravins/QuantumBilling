defmodule QuantumBilling.Quotations.Quotation do
  @moduledoc """
  A quotation (estimate): the same client, lines and tax as an invoice, under
  its own number series, and never part of any tax figure.

  The stored status is Draft, Sent, Accepted or Declined. Expired is never
  stored: a Draft or Sent quotation past `valid_until` reads as Expired (see
  `effective_status/2`), so extending the date brings it back.

  An Accepted quotation converts into one invoice, linked by
  `invoices.quotation_id` (unique). A quotation with a linked invoice is
  converted and stays Accepted.

  Deleting sets `deleted_at` (the Bin). `public_token` is the bearer secret
  in the client's link, `/q/:slug/:token`.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias QuantumBilling.CustomFields
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Quotations.QuotationItem
  alias QuantumBilling.Tax
  alias QuantumBilling.TaxRates

  @type t :: %__MODULE__{}

  @statuses ~w(Draft Sent Accepted Declined)
  @filters ~w(Draft Sent Accepted Declined Expired)

  schema "quotations" do
    field :number, :string
    field :quotation_date, :date
    field :valid_until, :date
    field :status, :string, default: "Draft"
    field :revision, :integer, default: 1
    field :sent_revision, :integer
    field :place_of_supply, :string
    field :currency, :string, default: "INR"

    # Snapshotted when saved.
    field :client_name, :string
    field :client_gstin, :string
    field :client_pan, :string
    field :client_billing_address, :string
    field :client_email, :string
    field :client_state, :string
    field :client_city, :string
    field :client_pincode, :string
    field :client_tax_number, :string

    field :company_name, :string
    field :company_address, :string
    field :company_gstin, :string
    field :company_state, :string
    field :company_tax_number, :string

    field :tax_regime, :string, default: "gst"
    field :reverse_charge, :boolean, default: false
    field :prices_include_tax, :boolean, default: false
    field :round_to_whole_units, :boolean, default: true

    field :total_items, :integer, default: 0
    field :total_quantity, :decimal, default: Decimal.new(0)
    field :taxable_value, :integer, default: 0
    field :cgst_amount, :integer, default: 0
    field :sgst_amount, :integer, default: 0
    field :igst_amount, :integer, default: 0
    field :cess_amount, :integer, default: 0
    # GST reverse charge, as on an invoice (see `Invoice`).
    field :rc_cgst_amount, :integer, default: 0
    field :rc_sgst_amount, :integer, default: 0
    field :rc_igst_amount, :integer, default: 0
    field :rc_cess_amount, :integer, default: 0
    field :vat_amount, :integer, default: 0
    field :tax_breakdown, {:array, :map}, default: []
    field :round_off, :integer, default: 0
    field :grand_total, :integer, default: 0

    field :remarks, :string
    field :terms, :string
    field :layout_xml, :string
    field :custom_fields, :map, default: %{}
    field :public_token, :string
    # Set only by bin_changeset/1 and restore_changeset/1.
    field :deleted_at, :utc_datetime

    belongs_to :template, QuantumBilling.Templates.InvoiceTemplate
    belongs_to :client, QuantumBilling.Clients.Client
    belongs_to :user, QuantumBilling.Accounts.User
    has_many :items, QuotationItem, on_replace: :delete, preload_order: [asc: :position]
    # Present once the quotation has been converted.
    has_one :invoice, Invoice

    timestamps(type: :utc_datetime)
  end

  # Fields a person may set from the form.
  @castable ~w(quotation_date valid_until place_of_supply client_id client_name
               client_gstin client_pan client_billing_address client_email
               client_state client_city client_pincode client_tax_number
               reverse_charge remarks terms template_id currency)a

  # Set only by the application and passed as `trusted`, never read from params.
  @trusted ~w(number company_name company_address company_gstin company_state
              company_tax_number tax_regime prices_include_tax round_to_whole_units
              template_id layout_xml user_id)a

  def statuses, do: @statuses

  @doc "The statuses a list can filter by, Expired included."
  def filters, do: @filters

  @doc """
  Builds a quotation changeset with its lines. `status` is never cast: it moves
  only through `status_changeset/2`.
  """
  def changeset(quotation, attrs, trusted \\ %{}) do
    quotation
    |> cast(attrs, @castable)
    |> change(Map.take(trusted, @trusted))
    |> default_currency(attrs, trusted)
    |> Invoice.freeze_currency("quotation")
    |> ensure_public_token()
    |> validate_inclusion(:tax_regime, Tax.regime_codes())
    |> Invoice.validate_currency_regime()
    |> cast_items(attrs)
    |> validate_required([:quotation_date, :valid_until, :client_name])
    |> validate_length(:client_name, max: 255)
    |> Invoice.validate_place_of_supply()
    |> Invoice.validate_client_tax_number()
    |> Invoice.validate_reverse_charge_buyer()
    |> validate_inclusion(:currency, QuantumBilling.Currency.codes(),
      message: "is not a supported currency"
    )
    |> validate_valid_until()
    |> CustomFields.cast("quotation", attrs)
    |> Invoice.validate_has_items()
    |> Invoice.recalculate()
    |> unique_constraint(:number,
      message: "has already been used — check the quotation series in Settings"
    )
    |> check_constraint(:valid_until,
      name: :quotations_valid_until_after_date,
      message: "cannot be before the quotation date"
    )
  end

  @doc "Narrows `query` to quotations not in the Bin."
  def kept(query \\ __MODULE__) do
    from q in query, where: is_nil(q.deleted_at)
  end

  @doc "Narrows `query` to quotations in the Bin."
  def binned(query \\ __MODULE__) do
    from q in query, where: not is_nil(q.deleted_at)
  end

  @doc "Moves the quotation to the Bin."
  def bin_changeset(quotation), do: change(quotation, deleted_at: DateTime.utc_now(:second))

  @doc "Takes the quotation out of the Bin."
  def restore_changeset(quotation), do: change(quotation, deleted_at: nil)

  @doc "A fresh 192-bit random token for the public link. It is a bearer credential."
  def generate_public_token do
    "qt_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  @doc "Gives a quotation saved before links existed its token."
  def token_changeset(quotation), do: change(quotation, public_token: generate_public_token())

  defp ensure_public_token(changeset) do
    case get_field(changeset, :public_token) do
      blank when blank in [nil, ""] ->
        put_change(changeset, :public_token, generate_public_token())

      _present ->
        changeset
    end
  end

  @doc "Moves the stored status. Callers check the transition is allowed."
  def status_changeset(quotation, status) when status in @statuses do
    change(quotation, status: status)
  end

  @doc """
  The status to show on `today`: Draft or Sent past `valid_until` is Expired.
  """
  def effective_status(%__MODULE__{status: status, valid_until: %Date{} = valid_until}, today)
      when status in ["Draft", "Sent"] do
    if Date.before?(valid_until, today), do: "Expired", else: status
  end

  def effective_status(%__MODULE__{status: status}, _today), do: status

  @doc "Whether the quotation can still be edited (its stored status is Draft or Sent)."
  def editable?(%__MODULE__{status: status}), do: status in ["Draft", "Sent"]

  def needs_resend?(%__MODULE__{status: "Draft", revision: revision, sent_revision: sent_revision})
      when is_integer(sent_revision),
      do: revision > sent_revision

  def needs_resend?(_quotation), do: false

  def answerable?(%__MODULE__{} = quotation), do: not needs_resend?(quotation)

  @doc "Whether a linked invoice exists. Needs `:invoice` preloaded."
  def converted?(%__MODULE__{invoice: %Invoice{}}), do: true
  def converted?(%__MODULE__{}), do: false

  @doc "Whether the quotation is under VAT."
  def vat?(%__MODULE__{tax_regime: regime}), do: regime == "vat"

  defp default_currency(changeset, attrs, %{default_currency: code}) when is_binary(code) do
    given? = Enum.any?(["currency", :currency], &(Map.get(attrs, &1) not in [nil, ""]))

    if is_nil(changeset.data.id) and not given?,
      do: put_change(changeset, :currency, code),
      else: changeset
  end

  defp default_currency(changeset, _attrs, _trusted), do: changeset

  defp cast_items(changeset, attrs) do
    tax =
      if get_field(changeset, :tax_regime) == "vat",
        do: {:vat, TaxRates.rates_by_id()},
        else: :gst

    # Loaded once for every line, and only when a line sends values.
    definitions =
      if attrs |> item_attrs() |> Enum.any?(&custom_fields_sent?/1),
        do: CustomFields.active_definitions("quotation_item"),
        else: []

    currency = get_field(changeset, :currency)

    cast_assoc(changeset, :items,
      with: &QuotationItem.changeset(&1, &2, tax, definitions, currency),
      sort_param: :items_sort,
      drop_param: :items_drop
    )
  end

  defp item_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, "items", Map.get(attrs, :items)) do
      items when is_map(items) -> Map.values(items)
      items when is_list(items) -> items
      _none -> []
    end
  end

  defp item_attrs(_attrs), do: []

  defp custom_fields_sent?(item) when is_map(item),
    do: Map.has_key?(item, "custom_fields") or Map.has_key?(item, :custom_fields)

  defp custom_fields_sent?(_item), do: false

  defp validate_valid_until(changeset) do
    date = get_field(changeset, :quotation_date)
    valid_until = get_field(changeset, :valid_until)

    if date && valid_until && Date.before?(valid_until, date),
      do: add_error(changeset, :valid_until, "cannot be before the quotation date"),
      else: changeset
  end
end
