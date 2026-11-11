defmodule QuantumBilling.Webhooks.WebhookEvent do
  @moduledoc """
  One webhook received from an outside system: records that it was handled
  (so redeliveries are ignored) and what it said.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(processed ignored failed)

  schema "webhook_events" do
    field :provider, :string
    field :event_id, :string
    field :event_type, :string
    # No schema default: Ecto would encrypt it at compile time, before any key is set.
    field :payload, QuantumBilling.Encrypted.Map, redact: true
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
end
