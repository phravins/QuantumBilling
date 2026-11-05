defmodule QuantumBilling.Businesses.Business do
  @moduledoc """
  A firm on this installation, with its own Postgres schema. The slug is
  set once from the name (it is in payment links and webhook URLs).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @schema_prefix "public"
  schema "businesses" do
    field :name, :string
    field :slug, :string
    field :schema, :string
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "The name, which is all a person chooses."
  def name_changeset(business, attrs) do
    business
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
  end

  @doc """
  Turns a name into a slug of lowercase letters, digits and single hyphens
  (`"business"` if nothing is left).
  """
  def slugify(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    if slug == "", do: "business", else: slug
  end

  @doc "Whether the business has been archived."
  def archived?(%__MODULE__{archived_at: archived_at}), do: archived_at != nil
end
