defmodule QuantumBilling.EWayBills.PartBUpdate do
  @moduledoc """
  One Part-B entry: the vehicle for one leg of a consignment's journey.

  EWB-01 lists every leg, so they are rows. The bill's `vehicle_number` is
  still the current vehicle.
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
