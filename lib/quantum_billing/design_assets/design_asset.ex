defmodule QuantumBilling.DesignAssets.DesignAsset do
  @moduledoc """
  One uploaded image a business uses in its invoice designs.

  `path` is what `QuantumBilling.Uploads.store/2` returned (`/uploads/<hash>.<ext>`),
  and is set by the server, never cast from a form.
  """
  use Ecto.Schema

  @kinds ~w(background image)

  schema "design_assets" do
    field :path, :string
    field :kind, :string, default: "image"

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The kinds an asset may be recorded as."
  def kinds, do: @kinds
end
