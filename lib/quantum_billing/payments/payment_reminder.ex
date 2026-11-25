defmodule QuantumBilling.Payments.PaymentReminder do
  use Ecto.Schema
  import Ecto.Changeset

  schema "payment_reminders" do
    field :step, :integer
    field :sent_at, :utc_datetime

    belongs_to :invoice, QuantumBilling.Invoices.Invoice
  end

  def changeset(reminder, attrs) do
    reminder
    |> cast(attrs, [:invoice_id, :step, :sent_at])
    |> validate_required([:invoice_id, :step, :sent_at])
    |> unique_constraint([:invoice_id, :step])
  end
end
