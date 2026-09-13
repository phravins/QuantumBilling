defmodule QuantumBilling.Mail.Delivery do
  @moduledoc """
  One attempt to get a message to somebody.

  A row exists from the moment a message is queued, not from the moment it
  succeeds, so "queued" with a high attempt count and a `last_error` is the
  visible shape of a relay that is refusing mail — rather than silence.

  The body is deliberately not stored. An invoice email carries the invoice as
  a PDF, and keeping a copy of every one would turn this table into a second,
  unindexed archive of the invoices themselves; `invoice_id` points at the real
  one, which can be re-rendered at any time.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(queued sent failed)
  @kinds ~w(invoice payment_receipt test account)

  schema "email_deliveries" do
    field :to_email, :string
    field :kind, :string, default: "invoice"
    field :subject, :string
    field :status, :string, default: "queued"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :delivered_at, :utc_datetime

    belongs_to :invoice, QuantumBilling.Invoices.Invoice

    timestamps(type: :utc_datetime)
  end

  @doc "Builds the row for a message about to be attempted."
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:to_email, :kind, :subject, :status, :attempts, :invoice_id])
    |> validate_required([:to_email])
    |> validate_format(:to_email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:subject, max: 255)
    |> check_constraint(:status, name: :email_deliveries_status_known)
  end

  @doc "Records the outcome of an attempt."
  def status_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:status, :attempts, :last_error, :delivered_at])
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :email_deliveries_status_known)
  end

  def statuses, do: @statuses
  def kinds, do: @kinds
end
