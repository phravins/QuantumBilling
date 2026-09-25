defmodule QuantumBillingWeb.InvoiceDoc.PDFTest do
  @moduledoc """
  What comes out of the renderer, when there is a browser here to run it.
  """
  use ExUnit.Case, async: true

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

    # Chrome renamed the switch that turns the print header and footer off and
    # then ignored the old spelling, so every downloaded document carried the
    # date, a page number and the file:///tmp/... path it happened to be
    # rendered from across the bottom of a tax record.
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
