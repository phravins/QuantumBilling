defmodule QuantumBilling.Spreadsheet do
  @moduledoc """
  Reads the first sheet of an uploaded CSV or Excel (.xlsx) file into a header
  row and data rows of trimmed strings.

  CSV: RFC 4180 quoting; comma, semicolon or tab, guessed from the header
  line; UTF-8 (with or without a BOM), UTF-16 ("Unicode text" from Excel), or
  Latin-1 from older tools.

  XLSX is a zip of XML parts, read with `:zip`, `:zlib` and `Saxy`, so no extra
  dependency is needed. Saxy expands no external entities. A zip bomb is
  refused rather than inflated: the sizes the archive declares are checked
  first, then every part is inflated a chunk at a time, and reading stops once
  the parts together pass 50 MB, whatever the archive claims. The old binary
  `.xls` format is refused with a pointer to save as .xlsx or CSV.
  """

  import Bitwise

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

  # `budget` is how many more inflated bytes may be read. It starts at
  # @max_unzipped and every part read takes its real size from it.
  defp parse_xlsx(binary) do
    with {:ok, entries} <- zip_entries(binary),
         {:ok, sheet_path, budget} <- first_sheet_path(binary, entries, @max_unzipped),
         {:ok, shared, budget} <- shared_strings(binary, entries, budget),
         {:ok, xml, _budget} <- read_part(binary, entries, sheet_path, budget),
         {:ok, rows} <- sheet_rows(xml, shared) do
      to_table(rows)
    end
  end

  # The archive's parts as `name => {local header offset, compressed size}`.
  # The declared uncompressed sizes are only a fast first refusal: the
  # uploader writes them, so `inflate_part/4` never relies on them.
  defp zip_entries(binary) do
    case :zip.list_dir(binary) do
      {:ok, [_comment | entries]} ->
        declared =
          Enum.sum(
            for {:zip_file, _name, info, _comment, _offset, _comp} <- entries, do: elem(info, 1)
          )

        # The first entry wins if a name repeats.
        parts =
          for {:zip_file, name, _info, _comment, offset, comp_size} <- entries, reduce: %{} do
            acc -> Map.put_new(acc, to_string(name), {offset, comp_size})
          end

        cond do
          declared > @max_unzipped -> {:error, too_large()}
          not Map.has_key?(parts, "xl/workbook.xml") -> {:error, not_xlsx()}
          true -> {:ok, parts}
        end

      _error ->
        {:error, not_xlsx()}
    end
  end

  defp not_xlsx, do: "This doesn't look like an Excel (.xlsx) file."
  defp too_large, do: "The spreadsheet is too large to read."

  # A part's contents, or the message to show for it.
  defp read_part(binary, entries, name, budget) do
    case inflate_part(binary, entries, name, budget) do
      {:ok, _xml, _budget} = read -> read
      {:error, :too_large} -> {:error, too_large()}
      {:error, :unreadable, _left} -> {:error, not_xlsx()}
    end
  end

  # Reads a part from its local header, inflates at most `budget` bytes of it,
  # and checks its CRC-32 as `:zip` would. An unreadable part returns the budget
  # left after what it inflated before failing, so a fallback read can't spend
  # those bytes again.
  defp inflate_part(binary, entries, name, budget) do
    with {:ok, {offset, comp_size}} <- Map.fetch(entries, name),
         <<_before::binary-size(offset), 0x04034B50::little-32, _version::little-16,
           flags::little-16, method::little-16, _time_date::binary-size(4), crc::little-32,
           _sizes::binary-size(8), name_length::little-16, extra_length::little-16,
           _name::binary-size(name_length), _extra::binary-size(extra_length),
           data::binary-size(comp_size), after_data::binary>> <- binary,
         {:ok, crc} <- expected_crc(flags, crc, after_data),
         {:ok, contents, left} <- inflate_data(method, data, budget) do
      if :erlang.crc32(contents) == crc,
        do: {:ok, contents, left},
        else: {:error, :unreadable, left}
    else
      {:error, _reason, _left} = inflate_error -> inflate_error
      {:error, :too_large} -> {:error, :too_large}
      _missing_or_damaged -> {:error, :unreadable, budget}
    end
  end

  # With flag bit 3 the CRC follows the data, in a descriptor whose signature
  # is optional; otherwise it is in the local header.
  defp expected_crc(flags, crc, _after_data) when (flags &&& 0x08) == 0, do: {:ok, crc}

  defp expected_crc(_flags, _crc, <<0x08074B50::little-32, crc::little-32, _::binary>>),
    do: {:ok, crc}

  defp expected_crc(_flags, _crc, <<crc::little-32, _::binary>>), do: {:ok, crc}
  defp expected_crc(_flags, _crc, _after_data), do: :error

  # Method 0 is stored as is, 8 is deflate; .xlsx uses nothing else.
  defp inflate_data(0, data, budget) when byte_size(data) <= budget,
    do: {:ok, data, budget - byte_size(data)}

  defp inflate_data(0, _data, _budget), do: {:error, :too_large}

  defp inflate_data(8, data, budget) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_chunks(z, zlib(fn -> :zlib.safeInflate(z, data) end), [], budget)
    after
      :zlib.close(z)
    end
  end

  defp inflate_data(_method, _data, budget), do: {:error, :unreadable, budget}

  # safeInflate/2 hands back a small chunk at a time, so this stops within one
  # chunk of the budget however far the data would expand. Every chunk is
  # charged before the next is asked for, so a failure keeps them counted.
  defp inflate_chunks(z, {status, output}, chunks, budget)
       when status in [:continue, :finished] do
    left = budget - IO.iodata_length(output)

    cond do
      left < 0 ->
        {:error, :too_large}

      status == :continue ->
        inflate_chunks(z, zlib(fn -> :zlib.safeInflate(z, []) end), [output | chunks], left)

      # inflateEnd/1 refuses a stream that stopped before its end.
      zlib(fn -> :zlib.inflateEnd(z) end) == :ok ->
        {:ok, IO.iodata_to_binary(Enum.reverse([output | chunks])), left}

      true ->
        {:error, :unreadable, left}
    end
  end

  # A data error, or a preset dictionary .xlsx never uses.
  defp inflate_chunks(_z, _unreadable, _chunks, budget), do: {:error, :unreadable, budget}

  # A zlib call whose data error comes back as a value, not an exception.
  defp zlib(call) do
    call.()
  catch
    :error, _reason -> :data_error
  end

  # The first <sheet> in the workbook, through its relationship id.
  defp first_sheet_path(binary, entries, budget) do
    case inflate_part(binary, entries, "xl/workbook.xml", budget) do
      {:ok, workbook, budget} ->
        case handle(workbook, :workbook) do
          {:ok, %{sheet_rel: rel_id}} when is_binary(rel_id) ->
            sheet_from_rels(binary, entries, rel_id, budget)

          _no_rel ->
            fallback_sheet(entries, budget)
        end

      {:error, :too_large} ->
        {:error, too_large()}

      {:error, :unreadable, left} ->
        fallback_sheet(entries, left)
    end
  end

  defp sheet_from_rels(binary, entries, rel_id, budget) do
    case inflate_part(binary, entries, "xl/_rels/workbook.xml.rels", budget) do
      {:ok, rels_xml, budget} ->
        with {:ok, %{rels: rels}} <- handle(rels_xml, :rels),
             target when is_binary(target) <- Map.get(rels, rel_id),
             path = sheet_path(target),
             true <- Map.has_key?(entries, path) do
          {:ok, path, budget}
        else
          _no_target -> fallback_sheet(entries, budget)
        end

      {:error, :too_large} ->
        {:error, too_large()}

      {:error, :unreadable, left} ->
        fallback_sheet(entries, left)
    end
  end

  defp sheet_path("/" <> _absolute = target), do: String.trim_leading(target, "/")
  defp sheet_path(relative), do: "xl/" <> relative

  defp fallback_sheet(entries, budget) do
    if Map.has_key?(entries, "xl/worksheets/sheet1.xml"),
      do: {:ok, "xl/worksheets/sheet1.xml", budget},
      else: {:error, "The spreadsheet has no sheets."}
  end

  defp shared_strings(binary, entries, budget) do
    if Map.has_key?(entries, "xl/sharedStrings.xml") do
      with {:ok, xml, budget} <- read_part(binary, entries, "xl/sharedStrings.xml", budget),
           {:ok, %{strings: strings}} <- handle(xml, :shared_strings) do
        {:ok, strings |> Enum.reverse() |> List.to_tuple(), budget}
      end
    else
      {:ok, {}, budget}
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
