defmodule QuantumBilling.Notifications.Notification do
  @moduledoc """
  One entry in the in-app notification feed. Writing one never fails the action it describes.

    * `kind` - the source, and its icon
    * `severity` - `info`, `success`, `warning` or `error`
    * `path` - where clicking goes, or `nil`
    * `dedupe_key` - so a repeated producer writes one row
    * `read_at` - shared across the business
    * `recipient_id` - one person, or `nil` for the whole business
  """
  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(invoice payment e_way_bill compliance mail client system)
  @severities ~w(info success warning error)

  schema "notifications" do
    field :kind, :string
    field :title, :string
    field :body, :string
    field :path, :string
    field :severity, :string, default: "info"
    field :dedupe_key, :string
    field :read_at, :utc_datetime

    # Nil for the whole business; set for one person's own reminder.
    belongs_to :recipient, QuantumBilling.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @castable ~w(kind title body path severity dedupe_key read_at recipient_id)a

  @doc "Builds a notification changeset. A long title is truncated, not rejected."
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, @castable)
    |> update_change(:title, &truncate(&1, 200))
    |> update_change(:body, &truncate(&1, 500))
    |> validate_required([:kind, :title])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:severity, @severities)
    |> unique_constraint(:dedupe_key)
  end

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) > limit do
      String.slice(value, 0, limit - 1) <> "…"
    else
      value
    end
  end

  defp truncate(value, _limit), do: value
end
