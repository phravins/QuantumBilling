defmodule QuantumBilling.Recurring.RecurringProfile do
  @moduledoc """
  A schedule profile for automatically issuing recurring GST invoices.

  Deleting a profile sets `deleted_at` and moves it to the Bin. `kept/1` is the
  filter every read goes through, and the one that matters most is the billing
  sweep: a profile in the Bin must not go on issuing invoices.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias QuantumBilling.CustomFields

  @frequencies ["Monthly", "Quarterly", "Annually"]
  @statuses ["Active", "Paused"]

  schema "recurring_profiles" do
    field :title, :string
    field :frequency, :string, default: "Monthly"
    field :next_run_date, :date
    field :status, :string, default: "Active"
    field :auto_send_email, :boolean, default: true
    field :items_json, :string

    # Failure tracking and circuit breaker
    field :consecutive_failures, :integer, default: 0
    field :last_failed_at, :utc_datetime
    field :last_failure_reason, :string

    # Set when the profile is moved to the Bin. Never cast.
    field :deleted_at, :utc_datetime

    belongs_to :client, QuantumBilling.Clients.Client

    # Values for the business's own fields. Written only by CustomFields.cast/4.
    field :custom_fields, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @castable ~w(title frequency next_run_date status auto_send_email client_id items_json consecutive_failures last_failed_at last_failure_reason)a

  @max_circuit_failures 3

  def changeset(profile, attrs) do
    changeset =
      profile
      |> cast(attrs, @castable)
      |> validate_required([:title, :frequency, :next_run_date, :client_id])
      |> validate_inclusion(:frequency, @frequencies)
      |> validate_inclusion(:status, @statuses)
      |> CustomFields.cast("recurring_profile", attrs)

    if get_change(changeset, :status) == "Active" and profile.status == "Paused" do
      changeset
      |> put_change(:consecutive_failures, 0)
      |> put_change(:last_failure_reason, nil)
    else
      changeset
    end
  end

  @doc """
  Records an execution failure on the profile. If consecutive failures reach
  `max_failures`, the profile's status transitions to "Paused" (circuit breaker).
  """
  def record_failure_changeset(profile, reason, max_failures \\ @max_circuit_failures) do
    failures = (profile.consecutive_failures || 0) + 1
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reason_text = truncate_reason(reason)

    changes = %{
      consecutive_failures: failures,
      last_failed_at: now,
      last_failure_reason: reason_text
    }

    changes =
      if failures >= max_failures do
        Map.put(changes, :status, "Paused")
      else
        changes
      end

    change(profile, changes)
  end

  @doc """
  Resets failure tracking on successful billing.
  """
  def reset_failure_changeset(profile) do
    change(profile, consecutive_failures: 0, last_failure_reason: nil)
  end

  defp truncate_reason(reason) when is_binary(reason) do
    if String.length(reason) > 500 do
      String.slice(reason, 0, 497) <> "..."
    else
      reason
    end
  end

  defp truncate_reason(reason), do: reason |> inspect() |> truncate_reason()

  @doc "Narrows `query` to profiles that are not in the Bin."
  def kept(query \\ __MODULE__) do
    from p in query, where: is_nil(p.deleted_at)
  end

  @doc "Narrows `query` to profiles that are in the Bin."
  def binned(query \\ __MODULE__) do
    from p in query, where: not is_nil(p.deleted_at)
  end

  @doc "Moves a profile to the Bin."
  def bin_changeset(profile), do: change(profile, deleted_at: DateTime.utc_now(:second))

  @doc "Takes a profile back out of the Bin."
  def restore_changeset(profile), do: change(profile, deleted_at: nil)
end
