defmodule QuantumBilling.Recurring.RecurringProfile do
  @moduledoc """
  A schedule profile for automatically issuing recurring GST invoices.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @frequencies ["Monthly", "Quarterly", "Annually"]
  @statuses ["Active", "Paused"]

  schema "recurring_profiles" do
    field :title, :string
    field :frequency, :string, default: "Monthly"
    field :next_run_date, :date
    field :status, :string, default: "Active"
    field :auto_send_email, :boolean, default: true
    field :items_json, :string

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

  def frequencies, do: @frequencies
  def statuses, do: @statuses
end
