defmodule QuantumBillingWeb.InvoiceDoc.PDFTest do
  @moduledoc """
  What comes out of the renderer, when there is a browser here to run it.
  """
  use ExUnit.Case, async: false

  alias QuantumBillingWeb.InvoiceDoc.PDF

  @html """
  <!doctype html>
  <html>
    <body><h1>Tax Invoice</h1><p>INV-2026-0001</p></body>
  </html>
  """

  describe "render/2" do
    @describetag :pdf

    setup do
      if PDF.executable() do
        :ok
      else
        {:ok, skip: true}
      end
    end

    test "kills the browser process and cleans temporary files on timeout" do
      timeout_binary =
        System.find_executable("timeout") || System.find_executable("gtimeout")

      if timeout_binary do
        directory =
          Path.join(System.tmp_dir!(), "qb-pdf-test-#{System.unique_integer([:positive])}")

        File.mkdir_p!(directory)

        script = Path.join(directory, "fake-chrome")
        pid_file = Path.join(directory, "child.pid")

        File.write!(script, """
        #!/bin/sh
        sleep 30 &
        echo $! > "$FAKE_CHROME_PID_FILE"
        wait
        """)

        File.chmod!(script, 0o755)

        old_chrome = System.get_env("PDF_CHROME_PATH")
        old_pid_file = System.get_env("FAKE_CHROME_PID_FILE")

        System.put_env("PDF_CHROME_PATH", script)
        System.put_env("FAKE_CHROME_PID_FILE", pid_file)

        on_exit(fn ->
          if old_chrome,
            do: System.put_env("PDF_CHROME_PATH", old_chrome),
            else: System.delete_env("PDF_CHROME_PATH")

          if old_pid_file,
            do: System.put_env("FAKE_CHROME_PID_FILE", old_pid_file),
            else: System.delete_env("FAKE_CHROME_PID_FILE")

          File.rm_rf(directory)
        end)

        before =
          System.tmp_dir!()
          |> Path.join("qb-pdf-*")
          |> Path.wildcard()
          |> MapSet.new()

        assert {:error, :timeout} = PDF.render("<html></html>", timeout: 300)

        pid = File.read!(pid_file) |> String.trim()

        Process.sleep(1100)
        {process, _} = System.cmd("ps", ["-p", pid, "-o", "pid="])
        assert String.trim(process) == ""

        after_dirs =
          System.tmp_dir!()
          |> Path.join("qb-pdf-*")
          |> Path.wildcard()
          |> MapSet.new()

        assert after_dirs == before
      end
    end

    # Chrome renamed the header/footer switch; no date, page number or temp path
    # may print on a tax record.
    test "prints no date, page number or temporary path", context do
      unless context[:skip] do
        assert {:ok, pdf} = PDF.render(@html)
        assert <<"%PDF-", _rest::binary>> = pdf

        text = text_of(pdf)

        refute text =~ "file://"
        refute text =~ ~r{\d/\d}
        assert text =~ "Tax Invoice"
      end
    end
  end

  # Chrome writes the page text uncompressed or in Flate streams; pulling the
  # text out beats asserting on flags we cannot see from here.
  defp text_of(pdf) do
    case System.find_executable("pdftotext") do
      nil ->
        streams(pdf)

      binary ->
        path =
          Path.join(System.tmp_dir!(), "qb-pdf-test-#{System.unique_integer([:positive])}.pdf")

        File.write!(path, pdf)

        try do
          {text, 0} = System.cmd(binary, [path, "-"])
          text
        after
          File.rm(path)
        end
    end
  end

  defp streams(pdf) do
    ~r/stream\r?\n(.*?)\r?\nendstream/s
    |> Regex.scan(pdf, capture: :all_but_first)
    |> Enum.map_join(" ", fn [chunk] ->
      case inflate(chunk) do
        {:ok, text} -> text
        :error -> chunk
      end
    end)
  end

  defp inflate(chunk) do
    zstream = :zlib.open()

    try do
      :zlib.inflateInit(zstream)
      {:ok, zstream |> :zlib.inflate(chunk) |> IO.iodata_to_binary()}
    rescue
      _ -> :error
    after
      :zlib.close(zstream)
    end
  end
end
