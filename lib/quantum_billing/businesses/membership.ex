defmodule QuantumBilling.Businesses.Membership do
  @moduledoc """
  Who may work in a business, and as what.

  Roles belong to the membership, not the account: one person can own one firm
  and keep the books as staff in another.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Businesses.Business

  @roles ~w(owner staff)

  @schema_prefix "public"
  schema "memberships" do
    field :role, :string, default: "staff"

    belongs_to :user, User
    belongs_to :business, Business

    timestamps(type: :utc_datetime)
  end

  @doc "The roles a membership can hold."
  def roles, do: @roles

  @doc "Whether this membership owns its business."
  def owner?(%__MODULE__{role: "owner"}), do: true
  def owner?(_membership), do: false

  @doc "A new membership. The user and business are set by the caller, never cast."
  def changeset(membership, role) do
    membership
    |> change(role: role)
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :business_id], name: :memberships_user_id_business_id_index)
  end
end
