defmodule QuantumBilling.DesignAssets do
  @moduledoc """
  Which uploaded images belong to the current business.

  Upload names are content hashes, so a path says nothing about its owner.
  Everything that serves or inlines an image checks `owned?/1`: the logo, or
  an image recorded here on upload.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.DesignAssets.DesignAsset
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  @path_format ~r"\A/uploads/[a-z0-9]{8,64}\.(png|jpg|gif|webp)\z"

  @doc "Whether `path` has the shape of a stored upload. Says nothing about ownership."
  def path?(path) when is_binary(path), do: Regex.match?(@path_format, path)
  def path?(_path), do: false

  @doc """
  Records an uploaded image as this business's. Idempotent: uploading the same
  file twice hashes to the same path and records it once.
  """
  def record(path, kind \\ "image") when is_binary(path) do
    if path?(path) and kind in DesignAsset.kinds() do
      %DesignAsset{path: path, kind: kind}
      |> Repo.insert(on_conflict: :nothing, conflict_target: :path)

      :ok
    else
      {:error, :invalid_path}
    end
  end

  @doc "Every recorded path, oldest first."
  def list_paths do
    Repo.all(from a in DesignAsset, order_by: [asc: a.id], select: a.path)
  end

  @doc """
  Whether `path` is one of this business's design images. Files are shared by hash, so check before deleting.
  """
  def recorded?(path) when is_binary(path),
    do: Repo.exists?(from a in DesignAsset, where: a.path == ^path)

  def recorded?(_path), do: false

  @doc """
  Whether the current business may use and serve `path`: its logo, or an image
  it recorded.
  """
  # The logo is compared as stored (it is set by the server, and older logos may
  # predate the hashed names); a recorded asset must also look like an upload.
  def owned?(path) when is_binary(path) do
    Settings.get_organization().doc_logo_path == path or (path?(path) and recorded?(path))
  end

  def owned?(_path), do: false
end
