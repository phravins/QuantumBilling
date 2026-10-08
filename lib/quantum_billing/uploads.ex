defmodule QuantumBilling.Uploads do
  @moduledoc """
  Stores user-supplied files on local disk and hands back the path to serve them
  from.

  Files land in `priv/static/uploads`, which `QuantumBillingWeb.static_paths/0`
  lists so the endpoint will serve them. The stored name is derived from the
  file's own contents rather than the name it arrived with: a user-supplied
  filename has no business reaching the filesystem, and hashing means uploading
  the same image twice costs one file instead of two.

  Local disk rather than object storage because it works the moment you clone
  the repo. The seam is `store/2` and `delete/1` — swapping in S3 later means
  reimplementing those two, not chasing call sites.
  """

  # Bitmap formats only. Anything else is refused rather than stored and served
  # back to other people.
  #
  # SVG used to be accepted, filtered by a handful of regexes looking for
  # `<script`, `on…=` handlers and `javascript:` URLs. A blocklist over SVG does
  # not hold: `<animate attributeName="href" values="javascript:…">`,
  # `<set attributeName="onload" to="…">`, HTML-entity-encoded handlers and
  # `<use href="data:image/svg+xml;base64,…">` all walk straight past it. And
  # an upload here is served from this application's own origin, so a script
  # that survives runs with the application's privileges — able to read a CSRF
  # token off a page and act as whoever opened it.
  #
  # A logo does not need to be SVG. Keeping a parser-based allowlist current
  # against SVG bypasses is a standing cost for a format nothing was using.
  @content_types %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp"
  }

  @max_bytes 2_000_000

  @doc "The content types `store/2` accepts, for `allow_upload/3`."
  def accepted_content_types, do: Map.keys(@content_types)

  @doc "The file extensions `store/2` accepts, for `allow_upload/3`."
  def accepted_extensions, do: Map.values(@content_types)

  @doc "The largest file `store/2` will accept, in bytes."
  def max_bytes, do: @max_bytes

  @doc """
  Copies the file at `source_path` into the uploads directory.

  Returns `{:ok, "/uploads/<hash>.<ext>"}` — a path, not a filesystem location,
  because that is what a template needs. `content_type` decides the extension;
  the caller gets it from the upload entry rather than from the filename.
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

  # The declared content type decides the extension and the served
  # `Content-Type`, and it arrives from the browser. Checking the magic bytes
  # means a file cannot be stored as `.png` and served as `image/png` while
  # actually being something else — which is the other half of how an upload
  # turns into script on this origin.
  defp validate_content(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>, "image/png"), do: :ok
  defp validate_content(<<0xFF, 0xD8, 0xFF, _rest::binary>>, "image/jpeg"), do: :ok
  defp validate_content(<<"GIF87a", _rest::binary>>, "image/gif"), do: :ok
  defp validate_content(<<"GIF89a", _rest::binary>>, "image/gif"), do: :ok

  defp validate_content(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>, "image/webp"),
    do: :ok

  defp validate_content(_contents, type) do
    {:error, "does not look like a #{type} image"}
  end

  @doc """
  Removes a previously stored file, given the path `store/2` returned.

  Succeeds when the file is already gone: the caller's intent is that it should
  not be there, and a settings row pointing at a deleted file is exactly when
  this gets called.
  """
  def delete(nil), do: :ok

  def delete("/uploads/" <> name) do
    # Guard against a stored path being edited into something that escapes the
    # uploads directory. Names we write never contain a separator.
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
