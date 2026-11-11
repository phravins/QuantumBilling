defmodule QuantumBilling.Spreadsheet do
  @moduledoc """
  Reads the first sheet of an uploaded CSV or Excel (.xlsx) file into a header
  row and data rows of trimmed strings.

  CSV: RFC 4180 quoting; comma, semicolon or tab, guessed from the header
  line; UTF-8 (with or without a BOM), UTF-16 ("Unicode text" from Excel), or
  Latin-1 from older tools.

  XLSX is a zip of XML parts, read with `:zip` and `Saxy`, so no extra
  dependency is needed. Saxy expands no external entities. The archive's
  uncompressed size is checked before anything is unpacked, so a zip bomb is
  refused rather than inflated. The old binary `.xls` format is refused with a
  pointer to save as .xlsx or CSV.
  """

  alias QuantumBilling.Spreadsheet.XlsxHandler

  @max_bytes 5_000_000
  @max_rows 2_000
  @max_columns 100
  @max_unzipped 50_000_000

  @type table :: %{headers: [String.t()], rows: [[String.t()]]}

  def max_bytes, do: @max_bytes
  def max_rows, do: @max_rows

  @doc "Reads the file at `path`; `filename` (the user's name for it) picks the format."
  @spec read(Path.t(), String.t()) :: {:ok, table} | {:error, String.t()}
  def read(path, filename) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_bytes ->
        {:error, too_big()}

      {:ok, _stat} ->
        path |> File.read!() |> parse(filename)

      {:error, _reason} ->
        {:error, "The file could not be read. Try uploading it again."}
    end
  end

  @doc "Parses file contents; `filename` picks the format."
  @spec parse(binary, String.t()) :: {:ok, table} | {:error, String.t()}
  def parse(binary, _filename) when byte_size(binary) > @max_bytes, do: {:error, too_big()}

  def parse(binary, filename) do
    case filename |> to_string() |> Path.extname() |> String.downcase() do
      ext when ext in [".csv", ".txt", ".tsv"] -> binary |> to_utf8() |> parse_csv()
      ".xlsx" -> parse_xlsx(binary)
      ".xls" -> {:error, "Old .xls files can't be read. In Excel, save it as .xlsx or CSV."}
      _other -> {:error, "Upload a CSV or an Excel (.xlsx) file."}
    end
  end

  defp too_big, do: "The file is larger than #{div(@max_bytes, 1_000_000)} MB."

  # ── CSV ────────────────────────────────────────────────────────────────────

  defp to_utf8(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: to_utf8(rest)
  defp to_utf8(<<0xFF, 0xFE, rest::binary>>), do: from_unicode(rest, {:utf16, :little})
  defp to_utf8(<<0xFE, 0xFF, rest::binary>>), do: from_unicode(rest, {:utf16, :big})

  defp to_utf8(binary) do
    if String.valid?(binary), do: binary, else: from_unicode(binary, :latin1)
  end

  defp from_unicode(binary, encoding) do
    case :unicode.characters_to_binary(binary, encoding) do
      converted when is_binary(converted) -> converted
      _error -> :unicode.characters_to_binary(binary, :latin1)
    end
  end

  defp parse_csv(text) do
    separator = sniff_separator(text)

    text
    |> csv(separator, :start, [], [], [])
    |> to_table()
  end

  # The separator that appears most in the first line wins; comma on a tie.
  defp sniff_separator(text) do
    first_line = text |> String.split(["\r\n", "\n", "\r"], parts: 2) |> hd()

    [?,, ?;, ?\t]
    |> Enum.max_by(fn sep -> first_line |> :binary.matches(<<sep>>) |> length() end)
  end

  # A byte at a time: the separator, quote and line breaks are ASCII, which
  # never appears inside a multi-byte UTF-8 character.
  #   field  - the current cell's bytes, reversed
  #   row    - the current row's cells, reversed
  #   rows   - finished rows, reversed
  defp csv(<<?", ?", rest::binary>>, sep, :quoted, field, row, rows),
    do: csv(rest, sep, :quoted, [?" | field], row, rows)

  defp csv(<<?", rest::binary>>, sep, :quoted, field, row, rows),
    do: csv(rest, sep, :closed, field, row, rows)

  defp csv(<<byte, rest::binary>>, sep, :quoted, field, row, rows),
    do: csv(rest, sep, :quoted, [byte | field], row, rows)

  defp csv(<<?", rest::binary>>, sep, :start, field, row, rows),
    do: csv(rest, sep, :quoted, field, row, rows)

  defp csv(<<sep, rest::binary>>, sep, _state, field, row, rows),
    do: csv(rest, sep, :start, [], [cell(field) | row], rows)

  defp csv(<<?\r, ?\n, rest::binary>>, sep, _state, field, row, rows),
    do: csv(rest, sep, :start, [], [], [end_row(field, row) | rows])

  defp csv(<<byte, rest::binary>>, sep, _state, field, row, rows) when byte in [?\n, ?\r],
    do: csv(rest, sep, :start, [], [], [end_row(field, row) | rows])

  # Text after a closing quote is kept rather than refused.
  defp csv(<<byte, rest::binary>>, sep, _plain, field, row, rows),
    do: csv(rest, sep, :plain, [byte | field], row, rows)

  defp csv(<<>>, _sep, _state, [], [], rows), do: Enum.reverse(rows)
  defp csv(<<>>, _sep, _state, field, row, rows), do: Enum.reverse([end_row(field, row) | rows])

  defp cell(field), do: field |> Enum.reverse() |> IO.iodata_to_binary()
  defp end_row(field, row), do: Enum.reverse([cell(field) | row])

  # ── XLSX ───────────────────────────────────────────────────────────────────

  defp parse_xlsx(binary) do
    with {:ok, names} <- zip_entries(binary),
         {:ok, sheet_path} <- first_sheet_path(binary, names),
         {:ok, shared} <- shared_strings(binary, names),
         {:ok, xml} <- unzip_one(binary, sheet_path),
         {:ok, rows} <- sheet_rows(xml, shared) do
      to_table(rows)
    end
  end

  defp zip_entries(binary) do
    case :zip.list_dir(binary) do
      {:ok, [_comment | entries]} ->
        sizes =
          for {:zip_file, _name, info, _comment, _offset, _comp} <- entries, do: elem(info, 1)

        names =
          for {:zip_file, name, _info, _comment, _offset, _comp} <- entries, do: to_string(name)

        cond do
          Enum.sum(sizes) > @max_unzipped -> {:error, "The spreadsheet is too large to read."}
          "xl/workbook.xml" not in names -> {:error, not_xlsx()}
          true -> {:ok, names}
        end

      _error ->
        {:error, not_xlsx()}
    end
  end

  defp not_xlsx, do: "This doesn't look like an Excel (.xlsx) file."

  defp unzip_one(binary, name) do
    case :zip.unzip(binary, [:memory, {:file_list, [String.to_charlist(name)]}]) do
      {:ok, [{_name, xml}]} -> {:ok, xml}
      _missing -> {:error, not_xlsx()}
    end
  end

  # The first <sheet> in the workbook, through its relationship id.
  defp first_sheet_path(binary, names) do
    with {:ok, workbook} <- unzip_one(binary, "xl/workbook.xml"),
         {:ok, %{sheet_rel: rel_id}} when is_binary(rel_id) <- handle(workbook, :workbook),
         true <- "xl/_rels/workbook.xml.rels" in names,
         {:ok, rels_xml} <- unzip_one(binary, "xl/_rels/workbook.xml.rels"),
         {:ok, %{rels: rels}} <- handle(rels_xml, :rels),
         target when is_binary(target) <- Map.get(rels, rel_id) do
      path =
        if String.starts_with?(target, "/"),
          do: String.trim_leading(target, "/"),
          else: "xl/" <> target

      if path in names, do: {:ok, path}, else: fallback_sheet(names)
    else
      _no_rels -> fallback_sheet(names)
    end
  end

  defp fallback_sheet(names) do
    if "xl/worksheets/sheet1.xml" in names,
      do: {:ok, "xl/worksheets/sheet1.xml"},
      else: {:error, "The spreadsheet has no sheets."}
  end

  defp shared_strings(binary, names) do
    if "xl/sharedStrings.xml" in names do
      with {:ok, xml} <- unzip_one(binary, "xl/sharedStrings.xml"),
           {:ok, %{strings: strings}} <- handle(xml, :shared_strings) do
        {:ok, strings |> Enum.reverse() |> List.to_tuple()}
      end
    else
      {:ok, {}}
    end
  end

  defp sheet_rows(xml, shared) do
    case handle(xml, :sheet, %{shared: shared, max_rows: @max_rows + 1}) do
      {:ok, %{too_many?: true}} ->
        {:error, too_many_rows()}

      {:ok, %{rows: rows}} ->
        {:ok, rows |> Enum.reverse() |> Enum.map(&row_cells/1)}

      error ->
        error
    end
  end

  # A map of column index => value, as a list with the gaps filled.
  defp row_cells(cells) when map_size(cells) == 0, do: []

  defp row_cells(cells) do
    last = cells |> Map.keys() |> Enum.max() |> min(@max_columns - 1)
    for index <- 0..last, do: Map.get(cells, index, "")
  end

  defp handle(xml, kind, extra \\ %{}) do
    case Saxy.parse_string(xml, XlsxHandler, XlsxHandler.initial(kind, extra)) do
      {:ok, state} -> {:ok, state}
      {:halt, state, _rest} -> {:ok, state}
      {:error, _reason} -> {:error, "The spreadsheet could not be read. Is it damaged?"}
    end
  end

  # ── Both ───────────────────────────────────────────────────────────────────

  defp to_table(rows) when is_list(rows) do
    rows =
      rows
      |> Enum.map(fn row -> row |> Enum.take(@max_columns) |> Enum.map(&String.trim/1) end)
      |> Enum.reject(fn row -> Enum.all?(row, &(&1 == "")) end)

    case rows do
      [] ->
        {:error, "The file is empty."}

      [_header] ->
        {:error, "The file has a header row but no clients under it."}

      [header | data] when length(data) > @max_rows ->
        _ = header
        {:error, too_many_rows()}

      [header | data] ->
        width = length(header)
        headers = header |> Enum.with_index(1) |> Enum.map(&header_name/1)
        data = Enum.map(data, &fit(&1, width))

        {:ok, %{headers: headers, rows: data}}
    end
  end

  defp to_table({:error, _message} = error), do: error

  defp too_many_rows,
    do: "The file has more than #{@max_rows} rows. Split it into smaller files."

  defp header_name({"", index}), do: "Column #{index}"
  defp header_name({name, _index}), do: name

  defp fit(row, width) do
    count = length(row)

    if count >= width,
      do: Enum.take(row, width),
      else: row ++ List.duplicate("", width - count)
  end
end
