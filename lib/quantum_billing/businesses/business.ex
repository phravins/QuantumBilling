defmodule QuantumBilling.Businesses.Business do
  @moduledoc """
  A firm kept on this installation: its own GSTIN, clients, invoices and
  numbering, in a Postgres schema of its own.

  The slug appears in payment links and the Razorpay webhook URL, so it is set
  once, from the name, and never changes after.
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
  Turns a name into a slug: lowercase letters, digits and single hyphens.

      iex> QuantumBilling.Businesses.Business.slugify("  Acme Traders (Pune) Pvt. Ltd ")
      "acme-traders-pune-pvt-ltd"

      iex> QuantumBilling.Businesses.Business.slugify("।।")
      "business"
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
