defmodule QuantumBilling.Uploads do
  @moduledoc """
  Stores uploaded files on local disk and returns the path they are served from.

  Files go to `priv/static/uploads`, which is not a static path:
  `UploadController` serves them after checking access. Names are content
  hashes, never the uploaded filename. `store/2` and `delete/1` are the seam
  for moving to object storage.
  """

  # Bitmap formats only. SVG is refused: a blocklist cannot make it safe to serve
  # from this origin.
  @content_types %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp"
  }

  @max_bytes 2_000_000

  @doc "The file extensions `store/2` accepts, for `allow_upload/3`."
  def accepted_extensions, do: Map.values(@content_types)

  @doc "The largest file `store/2` will accept, in bytes."
  def max_bytes, do: @max_bytes

  @doc """
  Copies `source_path` into uploads: `{:ok, "/uploads/<hash>.<ext>"}`. `content_type` sets the extension.
  """
  def store(source_path, content_type) do
    with {:ok, extension} <- extension_for(content_type),
         {:ok, contents} <- read_within_limit(source_path),
         :ok <- validate_content(contents, content_type) do
      name = "#{hash(contents)}#{extension}"
      destination = Path.join(directory(), name)

      File.mkdir_p!(directory())

      case File.write(destination, contents) do
        :ok -> {:ok, "/uploads/#{name}"}
        {:error, reason} -> {:error, "could not be saved (#{:file.format_error(reason)})"}
      end
    end
  end

  # The magic bytes must match the declared type, which comes from the browser.
  defp validate_content(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>, "image/png"), do: :ok
  defp validate_content(<<0xFF, 0xD8, 0xFF, _rest::binary>>, "image/jpeg"), do: :ok
  defp validate_content(<<"GIF87a", _rest::binary>>, "image/gif"), do: :ok
  defp validate_content(<<"GIF89a", _rest::binary>>, "image/gif"), do: :ok

  defp validate_content(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>, "image/webp"),
    do: :ok

  defp validate_content(_contents, type) do
    {:error, "does not look like a #{type} image"}
  end

  @doc "Removes a stored file by its path. Succeeds if it is already gone."
  def delete(nil), do: :ok

  def delete("/uploads/" <> name) do
    # Refuse a stored path that escapes the uploads directory.
    if String.contains?(name, ["/", "\\", ".."]) do
      {:error, "not a stored upload"}
    else
      case File.rm(Path.join(directory(), name)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, :file.format_error(reason)}
      end
    end
  end

  def delete(_other), do: {:error, "not a stored upload"}

  @doc """
  The file and content type for a stored upload's name, or `:error` for anything else (paths, unknown types).
  """
  def locate(name) when is_binary(name) do
    with false <- String.contains?(name, ["/", "\\", "..", <<0>>]),
         {content_type, _extension} <-
           Enum.find(@content_types, fn {_type, ext} -> Path.extname(name) == ext end),
         file = Path.join(directory(), name),
         true <- File.regular?(file) do
      {:ok, file, content_type}
    else
      _not_a_stored_upload -> :error
    end
  end

  @doc "Where uploads are written. Public so tests can clean up after themselves."
  def directory do
    Path.join(:code.priv_dir(:quantum_billing), "static/uploads")
  end

  defp extension_for(content_type) do
    case Map.fetch(@content_types, content_type) do
      {:ok, extension} -> {:ok, extension}
      :error -> {:error, "must be a PNG, JPEG, GIF or WebP image"}
    end
  end

  defp read_within_limit(source_path) do
    case File.read(source_path) do
      {:ok, contents} when byte_size(contents) > @max_bytes ->
        {:error, "must be smaller than #{div(@max_bytes, 1_000_000)}MB"}

      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error, "could not be read (#{:file.format_error(reason)})"}
    end
  end

  defp hash(contents) do
    :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end
end
