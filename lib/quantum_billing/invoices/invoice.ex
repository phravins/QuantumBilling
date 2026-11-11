defmodule QuantumBilling.Invoices.Invoice do
  @moduledoc """
  An invoice, under India GST or VAT (`tax_regime`, snapshotted at creation).

  Under GST, the same state as the issuing company splits tax into CGST and
  SGST; otherwise it is IGST. Under VAT, tax is worked out per rate (see
  `QuantumBilling.Tax.VAT`). Totals are computed by `recalculate/1` at save time and stored,
  so an invoice keeps what was billed. Deleting sets `deleted_at` (the Bin);
  `kept/1` filters binned invoices out of every read.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias QuantumBilling.CustomFields
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Tax
  alias QuantumBilling.TaxRates

  @invoice_types [
    "Tax Invoice",
    "Bill of Supply",
    "Export Invoice",
    "Credit Note",
    "Debit Note"
  ]

  # Label to days. "Custom" leaves the due date to be set by hand.
  @payment_terms [
    {"Due on Receipt", 0},
    {"Net 7 Days", 7},
    {"Net 15 Days", 15},
    {"Net 30 Days", 30},
    {"Net 45 Days", 45},
    {"Net 60 Days", 60},
    {"Custom", nil}
  ]

  @statuses [
    "Draft",
    "Pending E-Invoice",
    "E-Invoice Generated",
    "E-Invoice Failed",
    "Paid",
    "Cancelled"
  ]

  schema "invoices" do
    field :invoice_number, :string
    field :invoice_type, :string, default: "Tax Invoice"
    field :invoice_date, :date
    field :due_date, :date
    field :payment_terms, :string
    field :place_of_supply, :string

    # Snapshotted at issue.
    field :client_name, :string
    field :client_gstin, :string
    field :client_pan, :string
    field :client_billing_address, :string
    field :client_email, :string
    field :client_state, :string
    field :client_city, :string
    field :client_pincode, :string

    field :company_name, :string
    field :company_address, :string
    field :company_gstin, :string
    field :company_state, :string

    field :remarks, :string
    field :terms, :string

    field :total_items, :integer, default: 0
    field :total_quantity, :decimal, default: Decimal.new(0)
    field :taxable_value, :integer, default: 0
    field :cgst_amount, :integer, default: 0
    field :sgst_amount, :integer, default: 0
    field :igst_amount, :integer, default: 0
    field :cess_amount, :integer, default: 0
    field :round_off, :integer, default: 0
    field :grand_total, :integer, default: 0

    # The regime the invoice was raised under, snapshotted from the business.
    field :tax_regime, :string, default: "gst"
    field :vat_amount, :integer, default: 0
    # VAT only: one entry per rate, %{"name", "category", "rate_bp", "taxable", "tax"}.
    field :tax_breakdown, {:array, :map}, default: []
    field :company_tax_number, :string
    field :client_tax_number, :string
    field :reverse_charge, :boolean, default: false
    field :prices_include_tax, :boolean, default: false
    field :round_to_whole_units, :boolean, default: true

    field :status, :string, default: "Draft"

    # Government e-invoice (IRP)
    field :irn, :string
    field :ack_number, :string
    field :ack_date, :utc_datetime
    field :signed_qr_code, :string
    field :signed_invoice, :string
    # "live" when the IRP registered the IRN; "demo" when it was simulated.
    field :irn_mode, :string

    has_many :e_way_bills, QuantumBilling.EWayBills.EWayBill

    # Multi-currency and LUT export
    field :currency, :string, default: "INR"
    field :exchange_rate, :decimal, default: 1.0
    field :export_type, :string, default: "DOMESTIC"
    field :lut_number, :string

    # Razorpay / UPI
    field :razorpay_payment_link_id, :string
    field :razorpay_payment_url, :string
    field :razorpay_payment_id, :string

    # Token for the public payment page
    field :public_token, :string

    # The design this was issued under, frozen at issue.
    field :layout_xml, :string

    # Set only by bin_changeset/1 and restore_changeset/1.
    field :deleted_at, :utc_datetime

    # Values for the business's own fields. Written only by CustomFields.cast/4.
    field :custom_fields, :map, default: %{}

    belongs_to :template, QuantumBilling.Templates.InvoiceTemplate
    belongs_to :client, QuantumBilling.Clients.Client
    has_many :items, InvoiceItem, on_replace: :delete, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  # Fields a person (form) or integration (API) may set. IRN and Razorpay
  # fields are excluded: only the IRP's and Razorpay's answers write them.
  @castable ~w(invoice_type invoice_date due_date payment_terms
               place_of_supply client_id client_name client_gstin client_pan
               client_billing_address client_email client_state
               client_city client_pincode
               remarks terms template_id
               currency exchange_rate export_type lut_number
               client_tax_number reverse_charge)a

  # Set only by the application (number, company snapshot, layout, status) and
  # passed as `trusted`, never read from params.
  @trusted ~w(invoice_number company_name company_address company_gstin company_state
              status template_id layout_xml tax_regime prices_include_tax
              round_to_whole_units company_tax_number)a

  @doc """
  Builds an invoice changeset, including its line items.

  `attrs` is cast against `@permitted`; `trusted` is applied afterwards and wins.
  """
  def changeset(invoice, attrs, trusted \\ %{}) do
    invoice
    |> cast(attrs, @castable)
    |> change(Map.take(trusted, @trusted))
    |> default_currency(attrs, trusted)
    |> ensure_public_token()
    |> validate_inclusion(:tax_regime, Tax.regime_codes())
    |> cast_items(attrs)
    |> validate_required([:invoice_date, :client_name])
    |> validate_inclusion(:invoice_type, @invoice_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_place_of_supply()
    |> validate_client_tax_number()
    |> validate_inclusion(:currency, QuantumBilling.Currency.codes(),
      message: "is not a supported currency"
    )
    |> validate_due_date()
    |> CustomFields.cast("invoice", attrs)
    |> validate_has_items()
    |> recalculate()
    # Backstop for the numbering transaction: a clash becomes a changeset error.
    |> unique_constraint(:invoice_number,
      message: "has already been used — check the numbering series in Settings"
    )
  end

  # A new invoice bills in the business currency unless one was given.
  defp default_currency(changeset, attrs, %{default_currency: code}) when is_binary(code) do
    given? = Enum.any?(["currency", :currency], &(Map.get(attrs, &1) not in [nil, ""]))

    if is_nil(changeset.data.id) and not given?,
      do: put_change(changeset, :currency, code),
      else: changeset
  end

  defp default_currency(changeset, _attrs, _trusted), do: changeset

  defp cast_items(changeset, attrs) do
    cast_assoc(changeset, :items,
      with: item_changeset(attrs, changeset),
      sort_param: :items_sort,
      drop_param: :items_drop
    )
  end

  # Item definitions are loaded once for the whole invoice, and only when an item sends values.
  # Under VAT the rates are loaded once too, for the lines to snapshot.
  defp item_changeset(attrs, changeset) do
    definitions =
      if attrs |> item_attrs() |> Enum.any?(&custom_fields_sent?/1),
        do: CustomFields.active_definitions("invoice_item")

    tax =
      if get_field(changeset, :tax_regime) == "vat",
        do: {:vat, TaxRates.rates_by_id()},
        else: :gst

    &InvoiceItem.changeset(&1, &2, definitions, tax)
  end

  # India GST needs a state for the place of supply; VAT does not use one.
  defp validate_place_of_supply(changeset) do
    if vat?(changeset) do
      changeset
    else
      changeset
      |> validate_required([:place_of_supply])
      |> validate_inclusion(:place_of_supply, EWayBillForm.states())
      |> validate_optional_inclusion(:client_state, EWayBillForm.states())
    end
  end

  defp validate_client_tax_number(changeset) do
    changeset
    |> update_change(:client_tax_number, &Tax.normalize_tax_number/1)
    |> validate_length(:client_tax_number, max: 30)
  end

  @doc "Whether the invoice (or its changeset) is under VAT."
  def vat?(%Ecto.Changeset{} = changeset), do: get_field(changeset, :tax_regime) == "vat"
  def vat?(%__MODULE__{tax_regime: regime}), do: regime == "vat"
  def vat?(_invoice), do: false

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

  @doc "Narrows `query` to invoices not in the Bin. Every invoice read starts here."
  def kept(query \\ __MODULE__) do
    from i in query, where: is_nil(i.deleted_at)
  end

  @doc "Narrows `query` to invoices that are in the Bin."
  def binned(query \\ __MODULE__) do
    from i in query, where: not is_nil(i.deleted_at)
  end

  @doc "Whether this invoice is in the Bin."
  def binned?(%__MODULE__{deleted_at: deleted_at}), do: not is_nil(deleted_at)

  @doc "Moves an invoice to the Bin."
  def bin_changeset(invoice), do: change(invoice, deleted_at: DateTime.utc_now(:second))

  @doc "Takes an invoice back out of the Bin."
  def restore_changeset(invoice), do: change(invoice, deleted_at: nil)

  @doc "True when the invoice carries an IRN that was simulated, not registered with the IRP."
  def demo_irn?(%__MODULE__{irn: irn, irn_mode: mode}), do: is_binary(irn) and mode != "live"

  @doc """
  Records the IRP's answer on the invoice. `irn_mode` comes from the IRP client, never a form.
  """
  def einvoice_changeset(invoice, attrs) do
    invoice
    |> change(
      Map.take(attrs, [:irn, :ack_number, :ack_date, :signed_qr_code, :signed_invoice, :status])
    )
    |> put_change(:irn_mode, Map.fetch!(attrs, :irn_mode))
    |> validate_inclusion(:irn_mode, ["demo", "live"])
  end

  defp validate_due_date(changeset) do
    invoice_date = get_field(changeset, :invoice_date)
    due_date = get_field(changeset, :due_date)

    if invoice_date && due_date && Date.compare(due_date, invoice_date) == :lt do
      add_error(changeset, :due_date, "cannot be before the invoice date")
    else
      changeset
    end
  end

  defp validate_has_items(changeset) do
    case get_field(changeset, :items) do
      [] -> add_error(changeset, :items, "add at least one item")
      nil -> add_error(changeset, :items, "add at least one item")
      _present -> changeset
    end
  end

  @doc "Writes the computed totals onto the changeset. The form calls it for the live summary."
  def recalculate(changeset) do
    items = get_field(changeset, :items) || []
    totals = Tax.totals(items, tax_context(changeset))

    changeset
    |> put_change(:total_items, totals.total_items)
    |> put_change(:total_quantity, totals.total_quantity)
    |> put_change(:taxable_value, totals.taxable_value)
    |> put_change(:cgst_amount, totals.cgst_amount)
    |> put_change(:sgst_amount, totals.sgst_amount)
    |> put_change(:igst_amount, totals.igst_amount)
    |> put_change(:cess_amount, totals.cess_amount)
    |> put_change(:vat_amount, totals.vat_amount)
    |> put_change(:tax_breakdown, totals.tax_breakdown)
    |> put_change(:round_off, totals.round_off)
    |> put_change(:grand_total, totals.grand_total)
  end

  @doc "What `QuantumBilling.Tax.totals/2` needs to know about the invoice."
  def tax_context(%Ecto.Changeset{} = changeset) do
    %{
      regime: get_field(changeset, :tax_regime) || "gst",
      intra_state?: intra_state?(changeset),
      reverse_charge: get_field(changeset, :reverse_charge) == true,
      prices_include_tax: get_field(changeset, :prices_include_tax) == true,
      round_to_whole_units: get_field(changeset, :round_to_whole_units) != false
    }
  end

  @doc "GST totals for `items`; `intra_state?` picks CGST/SGST or IGST. See `QuantumBilling.Tax.GST`."
  defdelegate totals(items, intra_state?), to: QuantumBilling.Tax.GST

  @doc "Whether the supply is within the company's own state. Intra-state if the state is unset."
  def intra_state?(%Ecto.Changeset{} = changeset) do
    intra_state?(get_field(changeset, :place_of_supply), get_field(changeset, :company_state))
  end

  def intra_state?(%__MODULE__{} = invoice) do
    intra_state?(invoice.place_of_supply, invoice.company_state)
  end

  def intra_state?(_place_of_supply, nil), do: true
  def intra_state?(_place_of_supply, ""), do: true
  def intra_state?(place_of_supply, company_state), do: place_of_supply == company_state

  @doc """
  The due date implied by a payment term, or `nil` for "Custom".
  """
  def due_date_for(_invoice_date, nil), do: nil

  def due_date_for(%Date{} = invoice_date, term) do
    case Enum.find(@payment_terms, fn {label, _days} -> label == term end) do
      {_label, nil} -> nil
      {_label, days} -> Date.add(invoice_date, days)
      nil -> nil
    end
  end

  def due_date_for(_invoice_date, _term), do: nil

  defp validate_optional_inclusion(changeset, field, allowed) do
    case get_field(changeset, field) do
      blank when blank in [nil, ""] -> changeset
      _present -> validate_inclusion(changeset, field, allowed)
    end
  end

  @doc "A fresh 192-bit random token for the public payment page. It is a bearer credential."
  def generate_public_token do
    "inv_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  defp ensure_public_token(changeset) do
    case get_field(changeset, :public_token) do
      nil -> put_change(changeset, :public_token, generate_public_token())
      "" -> put_change(changeset, :public_token, generate_public_token())
      _present -> changeset
    end
  end

  def invoice_types, do: @invoice_types
  def payment_terms, do: Enum.map(@payment_terms, fn {label, _days} -> label end)
  def statuses, do: @statuses
end
