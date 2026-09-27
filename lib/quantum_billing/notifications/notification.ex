defmodule QuantumBilling.Notifications.Notification do
  @moduledoc """
  One line in the in-app feed behind the bell.

  A notification is a *record* of something that already happened, not a job to
  do: it is written after the invoice is saved, after the payment clears, after
  the bill is raised. Nothing in the application waits on one, and a failure to
  write one never fails the thing it was describing.

  ## Fields

    * `kind` — which part of the app it came from, and which icon it draws
    * `severity` — how it reads: `info`, `success`, `warning` or `error`
    * `path` — where clicking it goes, in-app; `nil` for a notice with nowhere
      to send you
    * `dedupe_key` — the caller's name for "this exact thing", so a producer
      that runs daily or is redelivered writes one row rather than many
    * `read_at` — shared, like the rest of the row; see the migration
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

    timestamps(type: :utc_datetime)
  end

  @castable ~w(kind title body path severity dedupe_key read_at)a

  @doc """
  Builds a notification changeset.

  The title is truncated rather than rejected. A notification is a side effect
  of something that has already succeeded, and refusing to record one because a
  client's name ran long would be the tail wagging the dog.
  """
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

  @doc "The kinds a notification may carry."
  def kinds, do: @kinds

  @doc "The severities a notification may carry."
  def severities, do: @severities
end
