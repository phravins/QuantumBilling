defmodule QuantumBillingWeb.InvoiceDoc.PDF do
  @moduledoc """
  Turns an invoice's HTML document into a PDF with headless Chromium.

  The browser comes from `PDF_CHROME_PATH`, then `:pdf_chrome_path` config,
  then `PATH`; without one `render/2` returns `{:error, :no_renderer}`.
  Chromium's sandbox is disabled, which is safe only because it renders our own
  template with scripts and network turned off.
  """

  require Logger

  @candidates ~w(chromium chromium-browser google-chrome google-chrome-stable chrome)

  @doc """
  Renders `html` to a PDF binary.

  Returns `{:ok, pdf}` or `{:error, reason}`: `:no_renderer`, `:timeout` or
  `{:exit, status, output}`. Option: `:timeout` in ms (default 20,000).
  """
  def render(html, opts \\ []) when is_binary(html) do
    case executable() do
      nil ->
        {:error, :no_renderer}

      binary ->
        timeout = Keyword.get(opts, :timeout, 20_000)

        directory =
          Path.join(System.tmp_dir!(), "qb-pdf-#{System.unique_integer([:positive])}")

        File.mkdir_p!(directory)

        try do
          source = Path.join(directory, "invoice.html")
          output = Path.join(directory, "invoice.pdf")
          File.write!(source, html)

          case run(binary, source, output, directory, timeout) do
            :ok -> read_output(output)
            {:error, reason} -> {:error, reason}
          end
        after
          File.rm_rf(directory)
        end
    end
  end

  @doc "Whether a PDF can be produced at all."
  def available?, do: executable() != nil

  @doc """
  The browser to use, or `nil`. Looked up per call, since releases run elsewhere than they build.
  """
  def executable do
    configured =
      System.get_env("PDF_CHROME_PATH") ||
        Application.get_env(:quantum_billing, :pdf_chrome_path)

    cond do
      is_binary(configured) and configured != "" and File.exists?(configured) -> configured
      is_binary(configured) and configured != "" -> nil
      true -> Enum.find_value(@candidates, &System.find_executable/1)
    end
  end

  defp run(binary, source, output, directory, timeout) do
    arguments = [
      "--headless=new",
      "--disable-gpu",
      # See the moduledoc: the input is our own file, not a page a user chose.
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-extensions",
      "--disable-background-networking",
      "--no-first-run",
      "--no-default-browser-check",
      "--virtual-time-budget=5000",
      "--user-data-dir=#{Path.join(directory, "profile")}",
      # Both spellings: Chrome renamed the switch and ignores the old one.
      "--no-pdf-header-footer",
      "--print-to-pdf-no-header",
      "--print-to-pdf=#{output}",
      "file://" <> source
    ]

    task =
      Task.async(fn ->
        System.cmd(binary, arguments, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, {:exit, status, String.slice(output, 0, 500)}}

      nil ->
        Logger.error("[PDF] #{binary} did not finish within #{timeout}ms")
        {:error, :timeout}
    end
  end

  defp read_output(path) do
    case File.read(path) do
      # Catches a browser that exits zero without writing a PDF.
      {:ok, <<"%PDF-", _rest::binary>> = pdf} -> {:ok, pdf}
      {:ok, _not_a_pdf} -> {:error, :not_a_pdf}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end
end
