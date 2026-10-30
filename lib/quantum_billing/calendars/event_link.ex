defmodule QuantumBilling.Calendars.EventLink do
  @moduledoc """
  Which remote event stands for a task or deadline, so that the next sync
  updates it rather than adding another.

  `fingerprint` is a hash of what was last sent: an item that still matches is
  skipped, which keeps a daily sync from rewriting every event.
  """
  use Ecto.Schema

  schema "calendar_event_links" do
    field :item_key, :string
    field :external_id, :string
    field :etag, :string
    field :fingerprint, :string
    field :due_date, :date

    belongs_to :connection, QuantumBilling.Calendars.Connection

    timestamps(type: :utc_datetime)
  end
end
