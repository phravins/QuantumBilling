defmodule QuantumBilling.Webhooks.Delivery do
  @moduledoc """
  One event on its way to one endpoint.

  `event_id` is shared by all endpoints and stable across retries, so receivers
  can dedupe. `body` is fixed at publish time. Statuses: `pending`,
  `succeeded`, `failed`, `cancelled`.
  """
  use Ecto.Schema

  schema "webhook_deliveries" do
    field :event_id, :string
    field :event_type, :string
    field :body, :string
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_status_code, :integer
    field :last_error, :string
    field :last_attempt_at, :utc_datetime
    field :delivered_at, :utc_datetime

    belongs_to :endpoint, QuantumBilling.Webhooks.Endpoint

    timestamps(type: :utc_datetime)
  end
end
