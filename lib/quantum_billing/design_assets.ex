defmodule QuantumBilling.DesignAssets do
  @moduledoc """
  Which uploaded images belong to the current business.

  Uploads share one directory and are named by a hash of their contents, so a
  path such as `/uploads/3f…a1.png` does not say whose it is. Everything that
  hands an image out — the upload controller, the PDF and public-page inliner,
  the design import — asks `owned?/1` first, and the answer is "this business
  has it as its logo, or recorded it here when it was uploaded".

  Runs in the business schema the caller is already inside, like every other
  tenant context.
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

  @doc "Every recorded asset, for the backup."
  def list_assets do
    Repo.all(from a in DesignAsset, order_by: [asc: a.id])
  end

  @doc """
  Whether `path` is recorded as one of this business's design images.

  Files are content-addressed, so a logo and a letterhead can be the same file;
  removing the logo must not delete a file a design still shows.
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
