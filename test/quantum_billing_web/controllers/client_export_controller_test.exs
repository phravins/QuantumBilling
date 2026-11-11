defmodule QuantumBillingWeb.ClientExportControllerTest do
  @moduledoc """
  The Clients page's Export: the list as CSV, narrowed like the screen, in
  columns the client import reads back.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.ApiFixtures, only: [invoice_fixture: 1]
  import QuantumBilling.CustomFieldsFixtures

  alias QuantumBilling.Clients
  alias QuantumBilling.Clients.Import
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Settings
  alias QuantumBilling.Spreadsheet

  setup :register_and_log_in_user

  @moduletag :tmp_dir

  defp client(attrs \\ %{}) do
    {:ok, client} =
      Clients.create_client(
        Map.merge(
          %{
            "client_type" => "Registered Business",
            "name" => "Acme Traders",
            "gstin" => "27AABCA1234A1Z5",
            "pan" => "AABCA1234A",
            "email" => "billing@acme.in",
            "phone" => "9876543210",
            "billing_line1" => "123 Business Park",
            "billing_city" => "Mumbai",
            "billing_state" => "Maharashtra (27)",
            "billing_pin" => "400093",
            "credit_limit" => "1500.50"
          },
          attrs
        )
      )

    client
  end

  # Read back with the import's own parser, so quoting is exercised too.
  defp export(conn, dir, params \\ []) do
    conn = get(conn, ~p"/clients/export?#{params}")
    path = Path.join(dir, "clients-#{System.unique_integer([:positive])}.csv")
    File.write!(path, response(conn, 200))

    {:ok, %{headers: headers, rows: rows}} = Spreadsheet.read(path, "clients.csv")
    Enum.map(rows, &(headers |> Enum.zip(&1) |> Map.new()))
  end

  defp names(rows), do: Enum.map(rows, & &1["Client name"])

  test "downloads the clients as a CSV attachment", %{conn: conn, tmp_dir: dir} do
    client()

    download = get(conn, ~p"/clients/export")

    assert response(download, 200)
    assert response_content_type(download, :csv)
    assert [disposition] = get_resp_header(download, "content-disposition")
    assert disposition =~ ~s(attachment; filename="clients.csv")

    assert [row] = export(conn, dir)
    assert row["Client name"] == "Acme Traders"
    assert row["GSTIN"] == "27AABCA1234A1Z5"
    assert row["PAN"] == "AABCA1234A"
    assert row["Phone country code"] == "+91"
    assert row["Phone"] == "9876543210"
    assert row["State"] == "Maharashtra (27)"
    assert row["PIN code"] == "400093"
    assert row["Credit limit"] == "1500.50"
    assert row["Status"] == "Active"
    # Ships to the billing address unless told otherwise.
    assert row["Shipping city"] == "Mumbai"
    refute Map.has_key?(row, "Tax number")
  end

  test "includes what each client still owes", %{conn: conn, tmp_dir: dir} do
    acme = client()
    invoice_fixture(%{client_id: acme.id, grand_total: 118_000})

    assert [%{"Outstanding" => "1180.00"}] = export(conn, dir)
  end

  test "follows the list's search and status", %{conn: conn, tmp_dir: dir} do
    client()

    dormant =
      client(%{
        "name" => "Beta Stores",
        "gstin" => "27AABCB1234B1Z5",
        "pan" => "AABCB1234B",
        "phone" => "9000000001"
      })

    {:ok, _dormant} = Clients.update_client(dormant, %{"status" => "Inactive"})

    assert names(export(conn, dir)) == ["Acme Traders", "Beta Stores"]
    assert names(export(conn, dir, q: "traders")) == ["Acme Traders"]
    assert names(export(conn, dir, status: "Inactive")) == ["Beta Stores"]
  end

  test "leaves out clients in the Bin", %{conn: conn, tmp_dir: dir} do
    client()

    gone =
      client(%{
        "name" => "Gone Ltd",
        "gstin" => "27AABCG1234G1Z5",
        "pan" => "AABCG1234G",
        "phone" => "9000000002"
      })

    {:ok, _binned} = Clients.delete_client(gone)

    assert names(export(conn, dir)) == ["Acme Traders"]
  end

  test "adds a column per custom field and follows its filter", %{conn: conn, tmp_dir: dir} do
    region =
      field_fixture("client", %{
        "label" => "Region",
        "type" => "select",
        "filterable" => true,
        "choices" => [%{"label" => "North"}, %{"label" => "South"}]
      })

    north = choice_id(region, "North")
    client(%{"custom_fields" => %{"region" => north}})

    client(%{
      "name" => "Beta Stores",
      "gstin" => "27AABCB1234B1Z5",
      "pan" => "AABCB1234B",
      "phone" => "9000000001"
    })

    assert [%{"Client name" => "Acme Traders", "Region" => "North"}] =
             export(conn, dir, custom: %{"region" => north})

    assert length(export(conn, dir, custom: %{"region" => "not-a-choice"})) == 2
  end

  test "a VAT business gets its own tax columns", %{conn: conn, tmp_dir: dir} do
    {:ok, _org} =
      Settings.update_section(
        Settings.get_organization(),
        %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => "100123456700003"},
        :tax
      )

    client(%{
      "gstin" => nil,
      "pan" => nil,
      "country" => "AE",
      "tax_number" => "100987654300003",
      "phone_country_code" => "+971",
      "phone" => "501234567",
      "billing_state" => nil,
      "billing_pin" => nil
    })

    assert [row] = export(conn, dir)
    assert row["Tax number"] == "100987654300003"
    assert row["Country"] == "AE"
    assert Map.has_key?(row, "Postal code")
    refute Map.has_key?(row, "GSTIN")
  end

  test "an exported file maps itself in the client import", %{conn: conn, tmp_dir: dir} do
    acme = client()
    conn = get(conn, ~p"/clients/export")
    path = Path.join(dir, "clients.csv")
    File.write!(path, response(conn, 200))
    {:ok, %{headers: headers, rows: rows}} = Spreadsheet.read(path, "clients.csv")

    definitions = CustomFields.active_definitions("client")
    mapping = Import.suggest_mapping(headers, definitions)
    mapped = for {index, target} <- mapping, target != "", into: %{}, do: {target, index}

    for target <-
          ~w(name client_type gstin pan country email phone_country_code phone billing_line1
             billing_city billing_state billing_pin payment_terms_days credit_limit status) do
      assert Map.has_key?(mapped, target), "#{target} is not mapped"
    end

    # Once the original is in the Bin, its export imports as a new client.
    {:ok, _binned} = Clients.delete_client(acme)

    assert [%{status: :ready, attrs: attrs}] =
             Import.classify(rows, mapping, "gst", definitions)

    assert attrs["gstin"] == acme.gstin
    assert attrs["billing_state"] == acme.billing_state
  end

  test "a signed-out request is refused" do
    assert build_conn() |> get(~p"/clients/export") |> response(403)
  end
end
