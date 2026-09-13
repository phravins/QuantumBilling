defmodule QuantumBilling.Webhooks.WebhookEvent do
  @moduledoc """
  One webhook received from an outside system.

  The row exists to answer two questions: has this event already been handled,
  and what did it say. The first is what makes the handler idempotent — payment
  providers retry until they get a 2xx and may deliver the same event twice
  regardless — and the second is what makes a disputed payment investigable
  without asking the provider to resend anything.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(processed ignored failed)

  schema "webhook_events" do
    field :provider, :string
    field :event_id, :string
    field :event_type, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "processed"
    field :error, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:provider, :event_id, :event_type, :payload, :status, :error])
    |> validate_required([:provider, :event_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:provider, :event_id])
  end

  def statuses, do: @statuses
end
