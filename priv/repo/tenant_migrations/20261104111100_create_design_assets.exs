defmodule QuantumBilling.Repo.TenantMigrations.CreateDesignAssets do
  use Ecto.Migration

  @moduledoc """
  The images a business has uploaded for its invoice designs: letterhead
  backgrounds, stamps, seals.

  Files live in the shared uploads directory under a content-hash name, so the
  name alone says nothing about which business owns it. This table is that
  record: the upload controller serves a file only to the business that lists
  it here (or has it as its logo), and the PDF renderer inlines only those.
  """

  def change do
    create table(:design_assets) do
      add :path, :string, null: false
      add :kind, :string, null: false, default: "image"

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:design_assets, [:path])
  end
end
