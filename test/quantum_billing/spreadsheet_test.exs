defmodule QuantumBilling.SpreadsheetTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Spreadsheet

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
end
