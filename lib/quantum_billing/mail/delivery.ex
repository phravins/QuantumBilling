defmodule QuantumBilling.Mail.Delivery do
  @moduledoc """
  One message's delivery record, created when it is queued (so a failing relay
  shows as attempts plus `last_error`). The body is not stored; `invoice_id`
  points at the invoice.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(queued sent failed)
  @kinds ~w(invoice payment_receipt test account e_way_bill reminder)

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
end
