defmodule QuantumBilling.Webhooks.Delivery do
  @moduledoc """
  One event on its way to one endpoint.

  `event_id` is the event's, shared by every endpoint that receives it and
  unchanged across retries, so a receiver can drop a repeat by remembering the
  ids it has handled. `body` is frozen when the event is published: a retry
  sends the same bytes, and only the signature's timestamp is new.

  Statuses: `pending` (queued or retrying), `succeeded`, `failed` (gave up, or
  refused by the endpoint), `cancelled` (the endpoint was disabled or removed
  before it went).
  """
  use Ecto.Schema

  @statuses ~w(pending succeeded failed cancelled)

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

  def statuses, do: @statuses
end
