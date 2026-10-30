defmodule QuantumBilling.InstallationSettings do
  @moduledoc """
  The sign-in rules, which protect the whole installation rather than one
  business: the IP allowlist, the idle timeout and mandatory two-factor.

  They apply before anyone has chosen a business — on the sign-in page itself —
  so they cannot live with a business's own settings. There is one row.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias QuantumBilling.Repo

  @schema_prefix "public"
  schema "installation_settings" do
    field :allowed_ips, :string
    field :session_timeout_minutes, :integer, default: 60
    field :enforce_2fa, :boolean, default: false
    field :singleton, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @fields ~w(allowed_ips session_timeout_minutes enforce_2fa)a

  @doc "The fields that hold the rules."
  def fields, do: @fields

  @doc "The rules in force; the defaults when none have been saved."
  def get do
    Repo.one(from s in __MODULE__, where: s.singleton) || %__MODULE__{}
  end

  @doc "A changeset for the Security settings form."
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @fields)
    |> validate_number(:session_timeout_minutes, greater_than: 0, less_than_or_equal_to: 10_080)
    |> QuantumBilling.Settings.Organization.validate_allowed_ips()
  end

  @doc "Saves the rules."
  def update(%__MODULE__{} = settings, attrs) do
    settings
    |> changeset(attrs)
    |> Repo.insert_or_update()
  end
end
