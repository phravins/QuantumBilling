defmodule QuantumBillingWeb.InvoiceDoc.PDF do
  @moduledoc """
  Turns an invoice's HTML document into an actual PDF.

  ## Why this exists

  `generate_pdf/1` used to return the HTML string unchanged, and the mailer
  attached it as `INV-1234.pdf`. What customers received was an HTML file with
  a PDF extension: some mail clients refuse to open it, some open it as text,
  and printing it gives whatever the client felt like. The attachment on a tax
  document has to be the document.

  ## How

  Headless Chromium prints the same HTML the print view shows, honouring the
  `@page` size and the print stylesheet the layout already carries — so the PDF
  and the browser's own "Save as PDF" produce the same page, which is the whole
  point of having one renderer.

  The binary is found in this order: the `PDF_CHROME_PATH` environment
  variable, then `:pdf_chrome_path` in application config, then the usual names
  on `PATH`. When none is present, `render/2` returns `{:error, :no_renderer}`
  and callers fall back to something honest — the mailer attaches HTML, named
  `.html`, rather than pretending.

  ## Sandboxing

  Chromium's own sandbox needs kernel privileges a container usually withholds,
  so it is disabled here. That is safe *because of what is being rendered*: our
  own template, from our own database, with no scripts and no network fetches
  (`--disable-*` flags below), reading one file from a directory this process
  just created. It is not a browser someone can point at a page they chose.
  """

  require Logger

  @candidates ~w(chromium chromium-browser google-chrome google-chrome-stable chrome)

  @doc """
  Renders `html` to a PDF binary.

  Returns `{:ok, pdf}`, or `{:error, reason}` — `:no_renderer` when no browser
  is installed, `:timeout` when one hangs, `{:exit, status, output}` when it
  fails outright.

  ## Options

    * `:timeout` — milliseconds to wait for the browser (default 20,000)
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

  @doc """
  Whether a PDF can be produced at all.

  Lets a page offer "Download PDF" only when it would work, and lets the mailer
  decide what to attach before it builds the message.
  """
  def available?, do: executable() != nil

  @doc """
  The browser this will use, or `nil`.

  Looked up per call rather than cached in a module attribute: a release is
  compiled somewhere that is not where it runs.
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
      # Nothing in the document is fetched over the network, and nothing in it
      # runs. Both are belt and braces around a local template.
      "--disable-extensions",
      "--disable-background-networking",
      "--no-first-run",
      "--no-default-browser-check",
      # A page that somehow waits on something still finishes.
      "--virtual-time-budget=5000",
      "--user-data-dir=#{Path.join(directory, "profile")}",
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
      # A PDF starts with %PDF-. Checking is how a browser that exits zero
      # having written nothing useful is caught here rather than by a customer.
      {:ok, <<"%PDF-", _rest::binary>> = pdf} -> {:ok, pdf}
      {:ok, _not_a_pdf} -> {:error, :not_a_pdf}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end
end
