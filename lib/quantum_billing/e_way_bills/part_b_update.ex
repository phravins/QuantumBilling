defmodule QuantumBilling.EWayBills.PartBUpdate do
  @moduledoc """
  One Part-B entry: the vehicle a consignment moved on for one leg of its
  journey.

  ## Why these are rows rather than columns

  Form GST EWB-01 prints Part-B as a table, not a field, because a consignment
  that changes vehicle in transit must show each leg — the rule is that Part-B
  is updated *before* the vehicle changes, and the bill then carries both
  entries. A single `vehicle_number` on the bill can only ever show the last
  one, which is exactly the history a check post would ask for.

  The bill's own `vehicle_number` still tracks the current vehicle, so
  everything that just wants "what is it on now" keeps working; this table is
  how it got there.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.EWayBills.EWayBill

  @transport_modes ["Road", "Rail", "Air", "Ship"]

  @castable ~w(vehicle_number mode_of_transport place reason updated_on e_way_bill_id)a

  schema "e_way_bill_part_b_updates" do
    field :vehicle_number, :string
    field :mode_of_transport, :string, default: "Road"
    field :place, :string
    field :reason, :string
    field :updated_on, :utc_datetime

    belongs_to :e_way_bill, EWayBill

    timestamps(type: :utc_datetime)
  end

  @doc "The modes of transport a Part-B entry accepts."
  def transport_modes, do: @transport_modes

  def changeset(part_b_update, attrs) do
    part_b_update
    |> cast(attrs, @castable)
    |> put_updated_on()
    |> validate_required([:vehicle_number, :mode_of_transport, :updated_on, :e_way_bill_id])
    |> validate_inclusion(:mode_of_transport, @transport_modes)
    |> validate_length(:vehicle_number, min: 4, max: 20)
    |> foreign_key_constraint(:e_way_bill_id)
  end

  defp put_updated_on(changeset) do
    case get_field(changeset, :updated_on) do
      nil -> put_change(changeset, :updated_on, DateTime.utc_now() |> DateTime.truncate(:second))
      _already_set -> changeset
    end
  end
end
