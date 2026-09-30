defmodule QuantumBilling.EWayBills.EWayBill do
  @moduledoc """
  One e-way bill raised against one invoice.

  ## Why `status` holds only two values

  A bill on the portal is Active, Cancelled or Expired, but only the first two
  are facts about the bill. Expiry is a fact about the clock: a bill valid
  until Tuesday becomes expired on Wednesday whether or not anything ran. So
  `status` stores `"Active"` or `"Cancelled"`, and
  `QuantumBilling.EWayBills.status/1` derives the third by comparing
  `valid_until` with now. Storing it would need a job to keep it true, and a
  job that fails would make the column lie.

  ## Cancellation

  Rule 138(9) allows cancellation within 24 hours of generation, with a reason,
  after which the number is spent and a fresh bill must be raised against the
  same document. Cancelled rows are kept: erasing them would destroy the audit
  trail the rule exists to create. A partial unique index on `invoice_id` where
  the status is not `"Cancelled"` is what keeps exactly one live bill per
  invoice while still permitting the re-issue.

  ## The Bin

  Deleting a bill here sets `deleted_at`. That is a statement about this
  application's records and nothing else: it is not a cancellation, the portal
  is not told, and the number stays as live or as spent there as it was. A
  binned bill stops counting as its invoice's live bill — the unique index
  leaves it out — so the invoice can have another raised.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias QuantumBilling.EWayBills.PartBUpdate
  alias QuantumBilling.Invoices.Invoice

  @statuses ["Active", "Cancelled"]
  @transport_modes ["Road", "Rail", "Air", "Ship"]

  @castable ~w(ewb_number ewb_date valid_until status distance_km mode_of_transport
               vehicle_number transporter_id transporter_name cancelled_at
               cancellation_reason invoice_id)a

  schema "e_way_bills" do
    field :ewb_number, :string
    field :ewb_date, :date
    field :valid_until, :naive_datetime
    field :status, :string, default: "Active"
    field :distance_km, :integer
    field :mode_of_transport, :string, default: "Road"
    field :vehicle_number, :string
    field :transporter_id, :string
    field :transporter_name, :string
    field :cancelled_at, :utc_datetime
    field :cancellation_reason, :string
    field :deleted_at, :utc_datetime

    belongs_to :invoice, Invoice
    has_many :part_b_updates, PartBUpdate, foreign_key: :e_way_bill_id

    timestamps(type: :utc_datetime)
  end

  @doc "The statuses a bill may be stored with. `\"Expired\"` is derived, not stored."
  def statuses, do: @statuses

  @doc "The modes of transport Part-A and Part-B accept."
  def transport_modes, do: @transport_modes

  @doc """
  Builds a changeset for creating or updating a bill.

  `invoice_id` is castable here because the context sets it from a loaded
  invoice, never from user input.
  """
  def changeset(e_way_bill, attrs) do
    e_way_bill
    |> cast(attrs, @castable)
    |> validate_required([:ewb_number, :ewb_date, :valid_until, :distance_km, :invoice_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode_of_transport, @transport_modes)
    |> validate_number(:distance_km, greater_than_or_equal_to: 0, less_than_or_equal_to: 4_000)
    |> foreign_key_constraint(:invoice_id)
    |> unique_constraint(:ewb_number)
    |> unique_constraint(:invoice_id,
      name: :e_way_bills_one_live_bill_per_invoice_index,
      message: "already has a live e-way bill"
    )
  end

  @doc """
  Marks a bill cancelled.

  The 24-hour window of Rule 138(9) is enforced by the context, which knows
  the current time; this records the decision.
  """
  def cancel_changeset(e_way_bill, attrs) do
    e_way_bill
    |> cast(attrs, [:cancellation_reason])
    |> put_change(:status, "Cancelled")
    |> put_change(:cancelled_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> validate_required([:cancellation_reason],
      message: "a reason is required to cancel an e-way bill"
    )
    |> validate_length(:cancellation_reason, min: 3, max: 255)
  end

  @doc "Narrows `query` to bills that are not in the Bin."
  def kept(query \\ __MODULE__) do
    from b in query, where: is_nil(b.deleted_at)
  end

  @doc "Narrows `query` to bills that are in the Bin."
  def binned(query \\ __MODULE__) do
    from b in query, where: not is_nil(b.deleted_at)
  end

  @doc "Moves a bill to the Bin."
  def bin_changeset(e_way_bill), do: change(e_way_bill, deleted_at: DateTime.utc_now(:second))

  @doc """
  Takes a bill back out of the Bin.

  Its invoice may have had another bill raised while this one was away, and an
  invoice carries one live bill. The constraint is declared so that coming back
  into a taken slot is an error on the changeset rather than a raise.
  """
  def restore_changeset(e_way_bill) do
    e_way_bill
    |> change(deleted_at: nil)
    |> unique_constraint(:invoice_id,
      name: :e_way_bills_one_live_bill_per_invoice_index,
      message: "already has a live e-way bill"
    )
  end
end
