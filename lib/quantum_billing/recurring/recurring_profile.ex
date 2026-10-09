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

  @frequencies ["Monthly", "Quarterly", "Annually"]
  @statuses ["Active", "Paused"]

  schema "recurring_profiles" do
    field :title, :string
    field :frequency, :string, default: "Monthly"
    field :next_run_date, :date
    field :status, :string, default: "Active"
    field :auto_send_email, :boolean, default: true
    field :items_json, :string

    # Set when the profile is moved to the Bin. Never cast.
    field :deleted_at, :utc_datetime

    belongs_to :client, QuantumBilling.Clients.Client

    timestamps(type: :utc_datetime)
  end

  @castable ~w(title frequency next_run_date status auto_send_email client_id items_json)a

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, @castable)
    |> validate_required([:title, :frequency, :next_run_date, :client_id])
    |> validate_inclusion(:frequency, @frequencies)
    |> validate_inclusion(:status, @statuses)
  end

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

  def frequencies, do: @frequencies
  def statuses, do: @statuses
end
