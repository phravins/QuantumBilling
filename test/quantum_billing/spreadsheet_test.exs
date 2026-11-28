defmodule QuantumBilling.SpreadsheetTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias QuantumBilling.Spreadsheet

  @mib 1_048_576
  @workbook ~s|<workbook><sheets><sheet name="S" sheetId="1"/></sheets></workbook>|
  @small_sheet ~s|<worksheet><sheetData><row><c t="inlineStr"><is><t>Name</t></is></c></row>| <>
                 ~s|<row><c t="inlineStr"><is><t>Asha</t></is></c></row></sheetData></worksheet>|

  describe "CSV" do
    test "reads quoted fields, escaped quotes and embedded line breaks" do
      csv = ~s|Name,Phone,Notes\r\n"Acme, Ltd",9876543210,"Says ""hi""\nthen leaves"\r\n|

      assert {:ok, %{headers: ["Name", "Phone", "Notes"], rows: rows}} =
               Spreadsheet.parse(csv, "clients.csv")

      assert rows == [["Acme, Ltd", "9876543210", ~s|Says "hi"\nthen leaves|]]
    end

    test "strips a UTF-8 BOM and trims cells" do
      csv = <<0xEF, 0xBB, 0xBF>> <> "Name , Phone\n  Asha  , 98765 43210 \n"

      assert {:ok, %{headers: ["Name", "Phone"], rows: [["Asha", "98765 43210"]]}} =
               Spreadsheet.parse(csv, "x.csv")
    end

    test "guesses semicolons and tabs" do
      assert {:ok, %{rows: [["A;B", "1"]]}} = Spreadsheet.parse(~s|Name;Qty\n"A;B";1\n|, "x.csv")
      assert {:ok, %{rows: [["A,B", "1"]]}} = Spreadsheet.parse("Name\tQty\nA,B\t1\n", "x.tsv")
    end

    test "reads Latin-1 and UTF-16 text" do
      latin1 = "Name\nCaf" <> <<0xE9>> <> "\n"
      assert {:ok, %{rows: [["Café"]]}} = Spreadsheet.parse(latin1, "x.csv")

      utf16 =
        <<0xFF, 0xFE>> <> :unicode.characters_to_binary("Name\nCafé\n", :utf8, {:utf16, :little})

      assert {:ok, %{rows: [["Café"]]}} = Spreadsheet.parse(utf16, "x.txt")
    end

    test "drops blank rows, pads short rows and names blank headers" do
      csv = "Name,,City\nAsha\n,,\nRavi,x,Pune,extra\n"

      assert {:ok, %{headers: ["Name", "Column 2", "City"], rows: rows}} =
               Spreadsheet.parse(csv, "x.csv")

      assert rows == [["Asha", "", ""], ["Ravi", "x", "Pune"]]
    end

    test "refuses empty files, header-only files and too many rows" do
      assert {:error, "The file is empty."} = Spreadsheet.parse("", "x.csv")
      assert {:error, "The file has a header row" <> _} = Spreadsheet.parse("Name\n", "x.csv")

      many = "Name\n" <> String.duplicate("a\n", Spreadsheet.max_rows() + 1)
      assert {:error, "The file has more than" <> _} = Spreadsheet.parse(many, "x.csv")
    end
  end

  describe "XLSX" do
    test "reads the first sheet with shared strings, numbers, inline strings and gaps" do
      sheet = """
      <?xml version="1.0" encoding="UTF-8"?>
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="D1" t="inlineStr"><is><t>PIN</t></is></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>9.87654321E+9</v></c><c r="D2"><v>411001.0</v></c></row>
        <row r="4"><c r="A4" t="s"><v>3</v></c><c r="B4" t="b"><v>1</v></c></row>
      </sheetData></worksheet>
      """

      strings = """
      <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <si><t>Name</t></si><si><t>Phone</t></si>
        <si><r><t>Acme </t></r><r><t>&amp; Co</t></r><rPh><t>ignored</t></rPh></si>
        <si><t xml:space="preserve"> Ravi </t></si>
      </sst>
      """

      assert {:ok, %{headers: headers, rows: rows}} =
               xlsx(%{"xl/worksheets/sheet1.xml" => sheet, "xl/sharedStrings.xml" => strings})
               |> Spreadsheet.parse("clients.xlsx")

      assert headers == ["Name", "Phone", "Column 3", "PIN"]
      assert rows == [["Acme & Co", "9876543210", "", "411001"], ["Ravi", "TRUE", "", ""]]
    end

    test "follows the workbook's relationship to the first sheet" do
      sheet =
        ~s|<worksheet><sheetData><row><c t="inlineStr"><is><t>Name</t></is></c></row>| <>
          ~s|<row><c t="inlineStr"><is><t>Asha</t></is></c></row></sheetData></worksheet>|

      files = %{
        "xl/workbook.xml" =>
          ~s|<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Clients" sheetId="1" r:id="rId7"/></sheets></workbook>|,
        "xl/_rels/workbook.xml.rels" =>
          ~s|<Relationships><Relationship Id="rId7" Target="worksheets/clients.xml"/></Relationships>|,
        "xl/worksheets/clients.xml" => sheet
      }

      assert {:ok, %{headers: ["Name"], rows: [["Asha"]]}} =
               files |> zip() |> Spreadsheet.parse("book.xlsx")
    end

    test "refuses a file that isn't a workbook" do
      assert {:error, "This doesn't look like an Excel" <> _} =
               Spreadsheet.parse("not a zip", "x.xlsx")

      assert {:error, "This doesn't look like an Excel" <> _} =
               %{"readme.txt" => "hi"} |> zip() |> Spreadsheet.parse("x.xlsx")
    end

    test "refuses an archive that unpacks too large without unpacking it" do
      # Highly compressible: a few KB zipped, 60 MB unzipped.
      huge = :binary.copy("0", 60_000_000)

      assert {:error, "The spreadsheet is too large to read."} =
               %{"xl/worksheets/sheet1.xml" => huge} |> xlsx() |> Spreadsheet.parse("x.xlsx")
    end
  end

  # The sizes in a zip's central directory are written by whoever made the file.
  # These archives claim each part is 1 byte while the real data is far larger.
  describe "XLSX whose archive understates its size" do
    test "stops inflating the sheet once it passes the limit" do
      archive =
        raw_zip([
          {"xl/workbook.xml", deflated([{@workbook, 1}]), :actual},
          {"xl/worksheets/sheet1.xml", padded_sheet(1024 * @mib), 1}
        ])

      # About 1 MB, well under the upload limit, yet it inflates to 1 GiB.
      assert byte_size(archive) < Spreadsheet.max_bytes()

      assert {:error, "The spreadsheet is too large to read."} =
               Spreadsheet.parse(archive, "x.xlsx")
    end

    test "stops inflating the shared strings once they pass the limit" do
      archive =
        raw_zip([
          {"xl/workbook.xml", deflated([{@workbook, 1}]), :actual},
          {"xl/worksheets/sheet1.xml", deflated([{@small_sheet, 1}]), :actual},
          {"xl/sharedStrings.xml", deflated([{"<sst>", 1}, {spaces(), 200}, {"</sst>", 1}]), 1}
        ])

      assert {:error, "The spreadsheet is too large to read."} =
               Spreadsheet.parse(archive, "x.xlsx")
    end

    test "counts every part against one limit" do
      # 30 MB of shared strings and a 30 MB sheet: each fits, together they don't.
      archive =
        raw_zip([
          {"xl/workbook.xml", deflated([{@workbook, 1}]), :actual},
          {"xl/worksheets/sheet1.xml", padded_sheet(30 * @mib), 1},
          {"xl/sharedStrings.xml", deflated([{"<sst>", 1}, {spaces(), 30}, {"</sst>", 1}]), 1}
        ])

      assert {:error, "The spreadsheet is too large to read."} =
               Spreadsheet.parse(archive, "x.xlsx")
    end

    test "a workbook just under the limit still imports" do
      archive =
        raw_zip([
          {"xl/workbook.xml", deflated([{@workbook, 1}]), :actual},
          {"xl/worksheets/sheet1.xml", padded_sheet(47 * @mib), :actual}
        ])

      assert {:ok, %{headers: ["Name"], rows: [["Asha"]]}} = Spreadsheet.parse(archive, "x.xlsx")
    end

    test "refuses data that isn't a complete deflate stream" do
      {data, crc, size} = deflated([{@small_sheet, 1}])
      cut = binary_part(data, 0, div(byte_size(data), 2))

      archive =
        raw_zip([
          {"xl/workbook.xml", deflated([{@workbook, 1}]), :actual},
          {"xl/worksheets/sheet1.xml", {cut, crc, size}, :actual}
        ])

      assert {:error, "This doesn't look like an Excel" <> _} =
               Spreadsheet.parse(archive, "x.xlsx")
    end

    test "refuses a part whose CRC doesn't match" do
      {data, crc, size} = deflated([{@small_sheet, 1}])

      archive =
        raw_zip([
          {"xl/workbook.xml", deflated([{@workbook, 1}]), :actual},
          {"xl/worksheets/sheet1.xml", {data, bxor(crc, 1), size}, :actual}
        ])

      assert {:error, "This doesn't look like an Excel" <> _} =
               Spreadsheet.parse(archive, "x.xlsx")
    end

    test "reads parts whose CRC and sizes follow the data in a descriptor" do
      archive =
        raw_zip([
          {"xl/workbook.xml", deflated([{@workbook, 1}]), :actual, :descriptor},
          {"xl/worksheets/sheet1.xml", deflated([{@small_sheet, 1}]), :actual, :descriptor}
        ])

      assert {:ok, %{headers: ["Name"], rows: [["Asha"]]}} = Spreadsheet.parse(archive, "x.xlsx")
    end
  end

  test "refuses old .xls and other formats" do
    assert {:error, "Old .xls files" <> _} = Spreadsheet.parse("x", "book.xls")
    assert {:error, "Upload a CSV or an Excel" <> _} = Spreadsheet.parse("x", "book.pdf")
  end

  test "read/2 checks the size on disk first" do
    path =
      Path.join(System.tmp_dir!(), "qb-spreadsheet-#{System.unique_integer([:positive])}.csv")

    File.write!(path, "Name\nAsha\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{rows: [["Asha"]]}} = Spreadsheet.read(path, "clients.csv")
    assert {:error, _} = Spreadsheet.read(path <> ".missing", "clients.csv")
  end

  defp xlsx(parts) do
    Map.merge(
      %{
        "xl/workbook.xml" =>
          ~s|<workbook><sheets><sheet name="S" sheetId="1"/></sheets></workbook>|
      },
      parts
    )
    |> zip()
  end

  defp zip(files) do
    entries = for {name, body} <- files, do: {String.to_charlist(name), body}
    {:ok, {_name, binary}} = :zip.create(~c"t.xlsx", entries, [:memory])
    binary
  end

  # A sheet with one client, padded with `padding` bytes of whitespace between
  # its rows (valid XML that the sheet reader skips).
  defp padded_sheet(padding) do
    deflated([
      {~s|<worksheet><sheetData><row><c t="inlineStr"><is><t>Name</t></is></c></row>|, 1},
      {spaces(), div(padding, @mib)},
      {~s|<row><c t="inlineStr"><is><t>Asha</t></is></c></row></sheetData></worksheet>|, 1}
    ])
  end

  defp spaces, do: :binary.copy(" ", @mib)

  # Raw deflate data for the `{binary, times}` parts in order, with its CRC-32
  # and size. Each part is compressed once, fully flushed so it stands alone,
  # and repeated: a gigabyte costs a few kilobytes to build.
  defp deflated(parts) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :best_compression, :deflated, -15, 8, :default)

    {data, crc, size} =
      Enum.reduce(parts, {[], 0, 0}, fn {part, times}, {data, crc, size} ->
        block = z |> :zlib.deflate(part, :full) |> IO.iodata_to_binary()
        part_crc = :erlang.crc32(part)

        crc =
          Enum.reduce(1..times//1, crc, fn _time, acc ->
            :erlang.crc32_combine(acc, part_crc, byte_size(part))
          end)

        {[data, :binary.copy(block, times)], crc, size + times * byte_size(part)}
      end)

    last = z |> :zlib.deflate("", :finish) |> IO.iodata_to_binary()
    :zlib.close(z)

    {IO.iodata_to_binary([data, last]), crc, size}
  end

  # A zip written by hand, so its headers can claim any uncompressed size.
  # Each entry is `{name, deflated, declared}` or `{name, deflated, declared,
  # :descriptor}`; `:actual` declares the real size. With `:descriptor` the
  # local header leaves the CRC and sizes empty and a data descriptor follows
  # the data, as zips written to a stream do.
  defp raw_zip(entries) do
    # 1 January 2026, 00:00, in DOS format.
    time = 0
    date = (2026 - 1980) <<< 9 ||| 1 <<< 5 ||| 1

    {body, directory} =
      Enum.reduce(entries, {<<>>, <<>>}, fn entry, {body, directory} ->
        {name, {data, crc, size}, declared, layout} =
          case entry do
            {name, deflated, declared} -> {name, deflated, declared, :header}
            {_name, _deflated, _declared, :descriptor} = entry -> entry
          end

        declared = if declared == :actual, do: size, else: declared
        sizes = <<crc::little-32, byte_size(data)::little-32, declared::little-32>>
        name_length = <<byte_size(name)::little-16>>

        {flags, local_sizes, descriptor} =
          case layout do
            :header -> {0, sizes, <<>>}
            :descriptor -> {0x08, <<0::96>>, <<0x08074B50::little-32, sizes::binary>>}
          end

        local =
          <<0x04034B50::little-32, 20::little-16, flags::little-16, 8::little-16, time::little-16,
            date::little-16, local_sizes::binary, name_length::binary, 0::little-16, name::binary,
            data::binary, descriptor::binary>>

        central =
          <<0x02014B50::little-32, 20::little-16, 20::little-16, flags::little-16, 8::little-16,
            time::little-16, date::little-16, sizes::binary, name_length::binary, 0::little-16,
            0::little-16, 0::little-16, 0::little-16, 0::little-32, byte_size(body)::little-32,
            name::binary>>

        {body <> local, directory <> central}
      end)

    count = length(entries)

    body <>
      directory <>
      <<0x06054B50::little-32, 0::little-16, 0::little-16, count::little-16, count::little-16,
        byte_size(directory)::little-32, byte_size(body)::little-32, 0::little-16>>
  end
end
