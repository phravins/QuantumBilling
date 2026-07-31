defmodule QuantumBilling.Invoices.Invoice do
  @moduledoc """
  A GST invoice.

  ## Intra-state versus inter-state

  Which taxes apply is decided by comparing the place of supply against the
  issuing company's state. Same state, and the tax splits into CGST and SGST;
  different states, and the whole amount is IGST. Both values come from
  `EWayBillForm.states()`, the same list `Client.billing_state` and
  `Organization.state` already use, so this is a plain comparison rather than
  anything that needs its own lookup.

  ## The totals are stored, not derived on read

  `recalculate/1` writes the totals into the changeset at save time. A saved
  invoice must keep showing what was actually billed even if this logic is
  changed later.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.Invoices.InvoiceItem

  @invoice_types [
    "Tax Invoice",
    "Bill of Supply",
    "Export Invoice",
    "Credit Note",
    "Debit Note"
  ]

  # Label to days. "Due on Receipt" is same-day; "Custom" leaves the due date
  # alone so it can be set by hand.
  @payment_terms [
    {"Due on Receipt", 0},
    {"Net 7 Days", 7},
    {"Net 15 Days", 15},
    {"Net 30 Days", 30},
    {"Net 45 Days", 45},
    {"Net 60 Days", 60},
    {"Custom", nil}
  ]

  @statuses ["Draft", "Pending E-Invoice", "E-Invoice Generated", "E-Invoice Failed", "Cancelled"]

  schema "invoices" do
    field :invoice_number, :string
    field :invoice_type, :string, default: "Tax Invoice"
    field :invoice_date, :date
    field :due_date, :date
    field :payment_terms, :string
    field :place_of_supply, :string

    # Snapshotted at issue. See the migration for why these are copied rather
    # than read live through the association.
    field :client_name, :string
    field :client_gstin, :string
    field :client_pan, :string
    field :client_billing_address, :string
    field :client_email, :string
    field :client_state, :string

    field :company_name, :string
    field :company_address, :string
    field :company_gstin, :string
    field :company_state, :string

    field :remarks, :string
    field :terms, :string

    field :total_items, :integer, default: 0
    field :total_quantity, :integer, default: 0
    field :taxable_value, :integer, default: 0
    field :cgst_amount, :integer, default: 0
    field :sgst_amount, :integer, default: 0
    field :igst_amount, :integer, default: 0
    field :cess_amount, :integer, default: 0
    field :round_off, :integer, default: 0
    field :grand_total, :integer, default: 0

    field :status, :string, default: "Draft"

    belongs_to :client, QuantumBilling.Clients.Client
    has_many :items, InvoiceItem, on_replace: :delete, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @castable ~w(invoice_number invoice_type invoice_date due_date payment_terms
               place_of_supply client_id client_name client_gstin client_pan
               client_billing_address client_email client_state
               company_name company_address company_gstin company_state
               remarks terms status)a

  @doc """
  Builds an invoice changeset, including its line items.

  `sort_param` and `drop_param` are what let the form add and remove item rows
  before anything is saved.
  """
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, @castable)
    |> cast_assoc(:items,
      with: &InvoiceItem.changeset/2,
      sort_param: :items_sort,
      drop_param: :items_drop
    )
    |> validate_required([:invoice_date, :place_of_supply, :client_name])
    |> validate_inclusion(:invoice_type, @invoice_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:place_of_supply, EWayBillForm.states())
    |> validate_optional_inclusion(:client_state, EWayBillForm.states())
    |> validate_due_date()
    |> validate_has_items()
    |> recalculate()
    # The transaction is what stops two saves being handed the same number.
    # This makes anything that still slips past it surface as a changeset error
    # rather than an unhandled Ecto.ConstraintError.
    |> unique_constraint(:invoice_number,
      message: "has already been used — check the numbering series in Settings"
    )
  end

  # A due date before the invoice date is a data entry error, not a business
  # case worth supporting.
  defp validate_due_date(changeset) do
    invoice_date = get_field(changeset, :invoice_date)
    due_date = get_field(changeset, :due_date)

    if invoice_date && due_date && Date.compare(due_date, invoice_date) == :lt do
      add_error(changeset, :due_date, "cannot be before the invoice date")
    else
      changeset
    end
  end

  # An invoice with nothing on it is not an invoice.
  defp validate_has_items(changeset) do
    case get_field(changeset, :items) do
      [] -> add_error(changeset, :items, "add at least one item")
      nil -> add_error(changeset, :items, "add at least one item")
      _present -> changeset
    end
  end

  @doc """
  Writes the computed totals onto the changeset.

  Public so the form can call it on every keystroke to drive the live summary
  panel without saving anything.
  """
  def recalculate(changeset) do
    items = get_field(changeset, :items) || []
    totals = totals(items, intra_state?(changeset))

    changeset
    |> put_change(:total_items, totals.total_items)
    |> put_change(:total_quantity, totals.total_quantity)
    |> put_change(:taxable_value, totals.taxable_value)
    |> put_change(:cgst_amount, totals.cgst_amount)
    |> put_change(:sgst_amount, totals.sgst_amount)
    |> put_change(:igst_amount, totals.igst_amount)
    |> put_change(:cess_amount, totals.cess_amount)
    |> put_change(:round_off, totals.round_off)
    |> put_change(:grand_total, totals.grand_total)
  end

  @doc """
  The totals for a set of items.

  `intra_state?` decides whether the tax splits into CGST/SGST or lands
  entirely in IGST.
  """
  def totals(items, intra_state?) do
    items = Enum.reject(items, &is_nil/1)

    taxable_value = Enum.reduce(items, 0, &(InvoiceItem.amount(&1) + &2))
    total_quantity = Enum.reduce(items, 0, &((&1.quantity || 0) + &2))
    tax = Enum.reduce(items, 0, &(InvoiceItem.tax(&1) + &2))

    {cgst, sgst, igst} =
      if intra_state? do
        cgst = div(tax, 2)
        # Deliberately not div(tax, 2) a second time: an odd tax amount would
        # lose a rupee, and the halves would not add back to the total.
        {cgst, tax - cgst, 0}
      else
        {0, 0, tax}
      end

    # Nothing on this form feeds a cess rate, so this is always zero for now.
    # The column exists so the summary can show the line the design has.
    cess = 0

    # Exact under integer arithmetic — there is nothing to round. Kept so the
    # column is correct if fractional pricing is ever introduced.
    round_off = 0

    %{
      total_items: length(items),
      total_quantity: total_quantity,
      taxable_value: taxable_value,
      cgst_amount: cgst,
      sgst_amount: sgst,
      igst_amount: igst,
      cess_amount: cess,
      round_off: round_off,
      grand_total: taxable_value + cgst + sgst + igst + cess + round_off
    }
  end

  @doc """
  Whether the supply is within the issuing company's own state.

  Defaults to intra-state when the company's state is not configured — a fresh
  installation has no organisation set up yet, and CGST/SGST is the common case.
  """
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

  def invoice_types, do: @invoice_types
  def payment_terms, do: Enum.map(@payment_terms, fn {label, _days} -> label end)
  def statuses, do: @statuses
end
