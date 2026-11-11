defmodule QuantumBillingWeb.ClientImportLiveTest do
  @moduledoc """
  The client import wizard: upload, match columns, review, import. And the
  ways into it from the Clients page, and the template download.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Clients

  setup :register_and_log_in_user

  @csv """
  Customer Name,GSTIN,Mobile,Email,Address,City,State,Pincode,Favourite colour
  Acme Traders,33AAACA1234A1Z5,+91 98765 43210,accounts@acme.example,12 Anna Salai,Chennai,Tamil Nadu,600018,Blue
  Beta Stores,,09000000001,,4 MG Road,Bengaluru,karnataka,560001,Red
  Broken Co,,123,,1 Main Rd,Pune,Maharashtra,4110,Green
  Acme Traders Copy,33AAACA1234A1Z5,9000000002,,12 Anna Salai,Chennai,Tamil Nadu,600018,
  """

  defp upload(view, name, content) do
    view
    |> file_input("#import-upload-form", :file, [
      %{name: name, content: content, type: "text/csv"}
    ])
    |> render_upload(name)
  end

  defp to_review(conn, csv \\ @csv) do
    {:ok, view, _html} = live(conn, ~p"/clients/import")
    upload(view, "clients.csv", csv)
    view |> form("#import-mapping-form") |> render_submit()
    view
  end

  defp count(view, id), do: view |> element("##{id} p.text-xl") |> render() |> text()

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  test "requires a signed-in user" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/clients/import")
  end

  test "starts on the upload step with a template link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients/import")

    assert has_element?(view, "#import-steps")
    assert has_element?(view, "#import-dropzone")
    assert has_element?(view, "#import-template[href='/clients/import/template.csv']")
    assert has_element?(view, "#import-required li", "Client name")
    refute has_element?(view, "#import-mapping-form")
  end

  test "matches the file's columns to client fields", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients/import")
    upload(view, "clients.csv", @csv)

    assert has_element?(view, "#import-file-name", "clients.csv")
    assert has_element?(view, "#import-column-0 option[selected][value='name']")
    assert has_element?(view, "#import-column-1 option[selected][value='gstin']")
    assert has_element?(view, "#import-column-2 option[selected][value='phone']")
    assert has_element?(view, "#import-column-7 option[selected][value='billing_pin']")
    # Nothing fits "Favourite colour", so it isn't imported.
    refute has_element?(view, "#import-column-8 option[selected]")
    assert has_element?(view, "#import-column-0", "Acme Traders")
    assert has_element?(view, "#import-required-billing_state .text-success")

    # Rows 2 and 5 share a GSTIN; the sample shows it once.
    gstin_sample = view |> element("#import-column-1") |> render() |> text()
    assert gstin_sample =~ "33AAACA1234A1Z5"
    refute gstin_sample =~ ~r/33AAACA1234A1Z5.*33AAACA1234A1Z5/s
  end

  test "won't go on until every required field has a column", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients/import")
    upload(view, "clients.csv", @csv)

    view |> form("#import-mapping-form", mapping: %{"5" => ""}) |> render_submit()

    assert has_element?(view, "#import-mapping-errors", "Choose a column for City.")
    assert has_element?(view, "#import-mapping-form")
    refute has_element?(view, "#import-summary")
  end

  test "sorts the rows into ready, needs fixing and already exists", %{conn: conn} do
    view = to_review(conn)

    assert count(view, "import-count-ready") == "2"
    assert count(view, "import-count-invalid") == "1"
    assert count(view, "import-count-duplicate") == "1"

    assert has_element?(view, "#import-row-2", "Ready")
    assert has_element?(view, "#import-row-4", "Phone must be 10 digits.")
    assert has_element?(view, "#import-row-5", "Same GSTIN as an earlier row in this file.")
    assert has_element?(view, "#import-submit", "Import 2 clients")
  end

  test "can show only the skipped rows", %{conn: conn} do
    view = to_review(conn)

    view |> element("#import-filter-problems") |> render_click()

    refute has_element?(view, "#import-row-2")
    assert has_element?(view, "#import-row-4")
    assert has_element?(view, "#import-row-5")

    view |> element("#import-filter-all") |> render_click()
    assert has_element?(view, "#import-row-2")
  end

  test "imports the ready rows and skips the rest", %{conn: conn} do
    view = to_review(conn)

    view |> element("#import-submit") |> render_click()

    assert has_element?(view, "#import-done", "2 clients imported")
    assert has_element?(view, "#import-view-clients[href='/clients']")

    names = Clients.list_clients() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["Acme Traders", "Beta Stores"]

    beta = Enum.find(Clients.list_clients(), &(&1.name == "Beta Stores"))
    assert beta.phone == "9000000001"
    assert beta.billing_state == "Karnataka (29)"
  end

  test "importing the same file again adds nothing", %{conn: conn} do
    conn |> to_review() |> element("#import-submit") |> render_click()

    view = to_review(conn)

    assert count(view, "import-count-ready") == "0"
    assert count(view, "import-count-duplicate") == "3"
    assert has_element?(view, "#import-submit[disabled]")
  end

  test "goes back to the columns, and starts over", %{conn: conn} do
    view = to_review(conn)

    view |> element("#import-back") |> render_click()
    assert has_element?(view, "#import-mapping-form")

    view |> element("#import-change-file") |> render_click()
    assert has_element?(view, "#import-dropzone")
    refute has_element?(view, "#import-mapping-form")
  end

  test "reads Excel files", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients/import")

    sheet = """
    <worksheet><sheetData>
    <row r="1"><c r="A1" t="inlineStr"><is><t>Name</t></is></c><c r="B1" t="inlineStr"><is><t>Phone</t></is></c><c r="C1" t="inlineStr"><is><t>Address</t></is></c><c r="D1" t="inlineStr"><is><t>City</t></is></c><c r="E1" t="inlineStr"><is><t>State</t></is></c><c r="F1" t="inlineStr"><is><t>PIN</t></is></c></row>
    <row r="2"><c r="A2" t="inlineStr"><is><t>Excel Co</t></is></c><c r="B2"><v>9876543210</v></c><c r="C2" t="inlineStr"><is><t>7 Park St</t></is></c><c r="D2" t="inlineStr"><is><t>Kolkata</t></is></c><c r="E2" t="inlineStr"><is><t>West Bengal</t></is></c><c r="F2"><v>700016</v></c></row>
    </sheetData></worksheet>
    """

    xlsx =
      zip(%{
        "xl/workbook.xml" =>
          ~s|<workbook><sheets><sheet name="S" sheetId="1"/></sheets></workbook>|,
        "xl/worksheets/sheet1.xml" => sheet
      })

    view
    |> file_input("#import-upload-form", :file, [
      %{
        name: "parties.xlsx",
        content: xlsx,
        type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      }
    ])
    |> render_upload("parties.xlsx")

    view |> form("#import-mapping-form") |> render_submit()

    assert count(view, "import-count-ready") == "1"
    view |> element("#import-submit") |> render_click()
    assert [%{name: "Excel Co", billing_pin: "700016"}] = Clients.list_clients()
  end

  test "explains a file it can't read", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients/import")

    upload(view, "clients.csv", "Name,Phone\n")

    assert has_element?(view, "#import-parse-error", "clients.csv couldn't be read")
    assert has_element?(view, "#import-dropzone")
  end

  test "refuses old .xls files with a way forward", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients/import")

    upload(view, "clients.xls", <<0xD0, 0xCF, 0x11, 0xE0>>)

    assert has_element?(view, "#import-parse-error", "save it as .xlsx or CSV")
  end

  describe "ways in" do
    test "the Clients page links to the import", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      assert has_element?(view, "#clients-import[href='/clients/import']")
      assert has_element?(view, "#clients-empty-import[href='/clients/import']")
    end

    test "the template downloads with the import's headers", %{conn: conn} do
      conn = get(conn, ~p"/clients/import/template.csv")

      assert response(conn, 200) =~ "Client name,Client type,GSTIN,PAN"
      assert response_content_type(conn, :csv)
      assert get_resp_header(conn, "content-disposition") |> hd() =~ "clients-import-template.csv"
    end

    test "the template needs a signed-in user" do
      conn = get(build_conn(), ~p"/clients/import/template.csv")
      assert conn.status in [302, 403]
    end
  end

  defp zip(files) do
    entries = for {name, body} <- files, do: {String.to_charlist(name), body}
    {:ok, {_name, binary}} = :zip.create(~c"t.xlsx", entries, [:memory])
    binary
  end
end
