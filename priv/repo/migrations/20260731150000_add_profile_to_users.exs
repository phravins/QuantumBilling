defmodule QuantumBilling.Repo.Migrations.AddProfileToUsers do
  use Ecto.Migration

  @moduledoc """
  Display details for the signed-in user: the name, phone and job title shown
  on the Account Settings page and in the sidebar.

  All nullable. Existing accounts have none of them, and none gates sign-in —
  identity remains the email address.
  """

  def change do
    alter table(:users) do
      add :full_name, :string
      add :phone, :string
      add :designation, :string
    end
  end
end
