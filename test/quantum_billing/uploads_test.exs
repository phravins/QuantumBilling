defmodule QuantumBilling.UploadsTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Uploads

  # A one-pixel PNG, so the bytes written are a real image rather than a string
  # that happens to be called one.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    source = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}.png")
    File.write!(source, @png)

    on_exit(fn -> File.rm(source) end)

    %{source: source}
  end

  defp cleanup(path) do
    on_exit(fn -> Uploads.delete(path) end)
    path
  end

  describe "store/2" do
    test "writes the file and returns a servable path", %{source: source} do
      assert {:ok, path} = Uploads.store(source, "image/png")
      cleanup(path)

      assert String.starts_with?(path, "/uploads/")
      assert String.ends_with?(path, ".png")

      on_disk = Path.join(Uploads.directory(), Path.basename(path))
      assert File.read!(on_disk) == @png
    end

    # The name comes from the contents, so the same image twice is one file.
    test "is idempotent for identical contents", %{source: source} do
      assert {:ok, first} = Uploads.store(source, "image/png")
      cleanup(first)
      assert {:ok, second} = Uploads.store(source, "image/png")

      assert first == second
    end

    test "names the file from its contents, not from the uploaded filename", %{source: source} do
      assert {:ok, path} = Uploads.store(source, "image/png")
      cleanup(path)

      refute path =~ "upload-"
      assert Path.basename(path, ".png") =~ ~r/^[0-9a-f]{32}$/
    end

    test "refuses a content type it will not serve", %{source: source} do
      assert {:error, message} = Uploads.store(source, "application/pdf")
      assert message =~ "PNG"
    end

    test "refuses a file over the size limit" do
      big = Path.join(System.tmp_dir!(), "big-#{System.unique_integer([:positive])}.png")
      File.write!(big, :binary.copy(<<0>>, Uploads.max_bytes() + 1))
      on_exit(fn -> File.rm(big) end)

      assert {:error, message} = Uploads.store(big, "image/png")
      assert message =~ "smaller than"
    end

    test "refuses SVG outright, however harmless it looks" do
      svg_path = Path.join(System.tmp_dir!(), "valid-#{System.unique_integer([:positive])}.svg")
      File.write!(svg_path, ~s[<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="40"/></svg>])
      on_exit(fn -> File.rm(svg_path) end)

      # SVG is refused outright: a blocklist over SVG does not hold, and uploads are
      # served from the application's own origin.
      assert {:error, message} = Uploads.store(svg_path, "image/svg+xml")
      assert message =~ "PNG, JPEG, GIF or WebP"
      refute message =~ "SVG"
    end

    test "refuses the bypasses the old regex filter would have missed" do
      bypasses = [
        ~s[<svg><animate attributeName="href" values="javascript:alert(1)"/></svg>],
        ~s[<svg><set attributeName="onload" to="alert(1)"/></svg>],
        ~s[<svg><use href="data:image/svg+xml;base64,PHN2Zz48c2NyaXB0PmFsZXJ0KDEpPC9zY3JpcHQ+PC9zdmc+"/></svg>],
        ~s[<svg><a xlink:href="&#106;avascript:alert(1)"><text>x</text></a></svg>]
      ]

      for {contents, index} <- Enum.with_index(bypasses) do
        path =
          Path.join(
            System.tmp_dir!(),
            "bypass-#{index}-#{System.unique_integer([:positive])}.svg"
          )

        File.write!(path, contents)
        on_exit(fn -> File.rm(path) end)

        assert {:error, _message} = Uploads.store(path, "image/svg+xml")
      end
    end

    test "refuses a file whose bytes are not the type it claims to be" do
      # The browser's content type sets the stored extension and the served
      # Content-Type, so it must match the bytes.
      path = Path.join(System.tmp_dir!(), "liar-#{System.unique_integer([:positive])}.png")
      File.write!(path, ~s[<svg><script>alert(1)</script></svg>])
      on_exit(fn -> File.rm(path) end)

      assert {:error, message} = Uploads.store(path, "image/png")
      assert message =~ "does not look like"
    end

    test "accepts each bitmap format by its own magic bytes" do
      samples = [
        {"image/png", <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>, ".png"},
        {"image/jpeg", <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0>>, ".jpg"},
        {"image/gif", <<"GIF89a", 0, 0>>, ".gif"},
        {"image/webp", <<"RIFF", 0, 0, 0, 0, "WEBP", 0, 0>>, ".webp"}
      ]

      for {type, bytes, extension} <- samples do
        path = Path.join(System.tmp_dir!(), "ok-#{System.unique_integer([:positive])}")
        File.write!(path, bytes)
        on_exit(fn -> File.rm(path) end)

        assert {:ok, stored} = Uploads.store(path, type), "#{type} was refused"
        cleanup(stored)
        assert String.ends_with?(stored, extension)
      end
    end
  end

  describe "delete/1" do
    test "removes a stored file", %{source: source} do
      {:ok, path} = Uploads.store(source, "image/png")
      on_disk = Path.join(Uploads.directory(), Path.basename(path))
      assert File.exists?(on_disk)

      assert Uploads.delete(path) == :ok
      refute File.exists?(on_disk)
    end

    test "treats an already-missing file as success" do
      assert Uploads.delete("/uploads/does-not-exist.png") == :ok
    end

    test "is a no-op for a blank path" do
      assert Uploads.delete(nil) == :ok
    end

    # A stored path is a database value, and a database value is worth
    # distrusting before it becomes a filesystem path.
    test "refuses to follow a path out of the uploads directory" do
      assert {:error, _} = Uploads.delete("/uploads/../../../etc/passwd")
      assert {:error, _} = Uploads.delete("/etc/passwd")
    end
  end
end
