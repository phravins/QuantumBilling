defmodule QuantumBilling.Clients.ImportTest do
  @moduledoc """
  Client import: matching headers to fields, tidying values typed in other
  apps, sorting rows into ready, needs fixing and already exists, and the
  all-or-nothing insert.
  """
  # Not async: the VAT tests switch the business's tax regime.
  use QuantumBilling.DataCase, async: false

  import QuantumBilling.CustomFieldsFixtures

  alias QuantumBilling.Clients
  alias QuantumBilling.Clients.Import
  alias QuantumBilling.Events
  alias QuantumBilling.Settings

  @headers [
    "Customer Name",
    "GSTIN/UIN",
    "Mobile No.",
    "E-mail",
    "Billing Address",
    "City",
    "State",
    "Pincode",
    "Payment Terms",
    "Opening Balance"
  ]

  defp mapping, do: Import.suggest_mapping(@headers, [])

  defp row(overrides \\ %{}) do
    base = %{
      name: "Acme Traders",
      gstin: "",
      phone: "9876543210",
      email: "accounts@acme.example",
      line1: "12 Anna Salai",
      city: "Chennai",
      state: "Tamil Nadu",
      pin: "600018",
      terms: "",
      balance: ""
    }

    v = Map.merge(base, overrides)
    [v.name, v.gstin, v.phone, v.email, v.line1, v.city, v.state, v.pin, v.terms, v.balance]
  end

  defp classify(rows, regime \\ "gst", definitions \\ []) do
    Import.classify(rows, mapping(), regime, definitions)
  end

  describe "suggest_mapping/2" do
    test "matches common export headers to client fields" do
      assert mapping() == %{
               "0" => "name",
               "1" => "gstin",
               "2" => "phone",
               "3" => "email",
               "4" => "billing_line1",
               "5" => "billing_city",
               "6" => "billing_state",
               "7" => "billing_pin",
               "8" => "payment_terms_days",
               "9" => "opening_balance"
             }
    end

    test "gives each field to the first matching column only" do
      assert Import.suggest_mapping(["Name", "Company Name", "Notes"], []) ==
               %{"0" => "name", "1" => "", "2" => "notes"}
    end

    test "leaves unknown columns unmapped" do
      assert Import.suggest_mapping(["Contact Name", "Favourite colour"], []) ==
               %{"0" => "", "1" => ""}
    end

    test "matches custom fields by label" do
      definition = field_fixture("client", %{"label" => "Sales region", "type" => "text"})

      assert Import.suggest_mapping(["Name", "Sales Region"], [definition]) ==
               %{"0" => "name", "1" => "custom:" <> definition.key}
    end
  end

  describe "validate_mapping/3" do
    test "accepts a mapping with every required field" do
      assert :ok = Import.validate_mapping(mapping(), "gst", [])
    end

    test "names missing and doubled fields" do
      doubled = %{"0" => "name", "1" => "name", "2" => "phone"}

      assert {:error, messages} = Import.validate_mapping(doubled, "gst", [])
      assert "Choose a column for City." in messages
      assert "Choose a column for State." in messages
      assert "Client name is chosen for 2 columns. Pick one." in messages
    end

    test "VAT needs a country but no state or PIN" do
      vat = %{
        "0" => "name",
        "1" => "phone",
        "2" => "country",
        "3" => "billing_line1",
        "4" => "billing_city"
      }

      assert :ok = Import.validate_mapping(vat, "vat", [])

      assert {:error, ["Choose a column for Country."]} =
               Import.validate_mapping(Map.delete(vat, "2"), "vat", [])
    end
  end

  describe "build_attrs/4" do
    defp attrs(overrides), do: Import.build_attrs(row(overrides), mapping(), "gst", [])

    test "splits phone numbers written the many ways people write them" do
      for phone <- ["+91 98765 43210", "0091-98765-43210", "919876543210", "09876543210"] do
        built = attrs(%{phone: phone})
        assert built["phone"] == "9876543210", "for #{phone}"
        assert built["phone_country_code"] == "+91", "for #{phone}"
      end

      built = attrs(%{phone: "+971 50 123 4567"})
      assert built["phone_country_code"] == "+971"
      assert built["phone"] == "501234567"
    end

    test "matches states by name, case or GST code" do
      for state <- ["tamil nadu", "TAMIL NADU", "Tamil Nadu (33)", "33"] do
        assert attrs(%{state: state})["billing_state"] == "Tamil Nadu (33)", "for #{state}"
      end
    end

    test "tidies GSTINs, amounts and payment terms" do
      built =
        attrs(%{gstin: "33 aaaca1234a1z5", terms: "Net 30", balance: "₹1,25,000.50"})

      assert built["gstin"] == "33AAACA1234A1Z5"
      assert built["payment_terms_days"] == "30"
      assert built["opening_balance"] == "125000.50"
      assert attrs(%{terms: "Due on receipt"})["payment_terms_days"] == "0"
      assert attrs(%{balance: "Rs. 2,000"})["opening_balance"] == "2000"
    end

    test "infers the client type from the GSTIN" do
      assert attrs(%{gstin: "33AAACA1234A1Z5"})["client_type"] == "Registered Business"
      assert attrs(%{})["client_type"] == "Unregistered"
    end

    test "reads client types written as other apps write them" do
      headers = ["Name", "GST Treatment"]
      mapping = Import.suggest_mapping(headers, [])

      for {given, expected} <- [
            {"registered business - regular", "Registered Business"},
            {"Composition", "Composition Scheme"},
            {"overseas", "Overseas"},
            {"consumer", "Consumer"}
          ] do
        assert Import.build_attrs(["A", given], mapping, "gst", [])["client_type"] == expected
      end
    end

    test "always ships to the billing address and defaults the country to India" do
      built = attrs(%{})
      assert built["shipping_same_as_billing"] == true
      assert built["country"] == "IN"
    end
  end

  describe "classify/4" do
    test "marks valid rows as ready" do
      assert [%{row: 2, status: :ready, name: "Acme Traders", phone: "+91 9876543210"}] =
               classify([row()])
    end

    test "explains why a row can't be imported" do
      assert [%{row: 2, status: :invalid, errors: errors}] =
               classify([row(%{phone: "12345", pin: "6000"})])

      assert "Phone must be 10 digits." in errors
      assert "PIN / postal code must be 6 digits." in errors
    end

    test "requires a GSTIN when the type says registered" do
      headers = ["Name", "Type", "Phone", "Address", "City", "State", "PIN"]
      mapping = Import.suggest_mapping(headers, [])

      values = ["Acme", "Registered", "9876543210", "12 Main Rd", "Chennai", "TN", "600018"]
      [result] = Import.classify([values], mapping, "gst", [])

      assert result.status == :invalid
      assert Enum.any?(result.errors, &String.starts_with?(&1, "GSTIN is required"))
      assert Enum.any?(result.errors, &String.starts_with?(&1, "State"))
    end

    test "skips clients that already exist, by GSTIN or by name and phone" do
      {:ok, _client} =
        Clients.create_client(%{
          "client_type" => "Registered Business",
          "name" => "Existing Co",
          "gstin" => "33AAACA1234A1Z5",
          "phone" => "9000000001",
          "billing_line1" => "1 Main Rd",
          "billing_city" => "Chennai",
          "billing_state" => "Tamil Nadu (33)",
          "billing_pin" => "600001"
        })

      rows = [
        row(%{name: "Renamed Co", gstin: "33aaaca1234a1z5"}),
        row(%{name: "existing co", phone: "+91 90000 00001"}),
        row(%{name: "New Co"})
      ]

      assert [
               %{
                 status: :duplicate,
                 errors: ["A client with GSTIN 33AAACA1234A1Z5 already exists."]
               },
               %{
                 status: :duplicate,
                 errors: ["A client with this name and phone already exists."]
               },
               %{status: :ready}
             ] = classify(rows)
    end

    test "a client in the Bin doesn't block its import" do
      {:ok, client} =
        Clients.create_client(%{
          "client_type" => "Unregistered",
          "name" => "Acme Traders",
          "phone" => "9876543210",
          "billing_line1" => "1 Main Rd",
          "billing_city" => "Chennai",
          "billing_state" => "Tamil Nadu (33)",
          "billing_pin" => "600001"
        })

      {:ok, _binned} = Clients.delete_client(client)

      assert [%{status: :ready}] = classify([row()])
    end

    test "skips rows repeated within the file" do
      rows = [
        row(%{gstin: "33AAACA1234A1Z5"}),
        row(%{name: "Other name", gstin: "33AAACA1234A1Z5", phone: "9000000002"}),
        row(%{name: "ACME TRADERS"}),
        row(%{name: "Fine Co", phone: "9000000003"})
      ]

      assert [
               %{status: :ready},
               %{status: :duplicate, errors: ["Same GSTIN as an earlier row in this file."]},
               %{
                 status: :duplicate,
                 errors: ["Same name and phone as an earlier row in this file."]
               },
               %{status: :ready}
             ] = classify(rows)
    end

    test "an invalid row doesn't make a later copy a duplicate" do
      rows = [row(%{pin: "1"}), row()]
      assert [%{status: :invalid}, %{status: :ready}] = classify(rows)
    end

    test "enforces required custom fields" do
      definition =
        field_fixture("client", %{
          "label" => "Account manager",
          "type" => "text",
          "required" => "true"
        })

      [result] = classify([row()], "gst", [definition])

      assert result.status == :invalid
      assert Enum.any?(result.errors, &String.contains?(&1, "Account manager"))
    end

    test "fills custom fields from their column" do
      definition = field_fixture("client", %{"label" => "Account manager", "type" => "text"})
      mapping = Map.put(mapping(), "10", "custom:" <> definition.key)

      [result] = Import.classify([row() ++ ["Priya"]], mapping, "gst", [definition])

      assert result.status == :ready
      assert result.attrs["custom_fields"] == %{definition.key => "Priya"}
    end
  end

  describe "VAT businesses" do
    setup do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => "100123456700003"},
          :tax
        )

      :ok
    end

    @vat_headers ["Company", "Country", "TRN", "Phone", "Street", "City"]

    test "reads country names and dials by country" do
      mapping = Import.suggest_mapping(@vat_headers, [])

      assert %{"1" => "country", "2" => "tax_number", "4" => "billing_line1"} = mapping

      values = [
        "Gulf Trading LLC",
        "United Arab Emirates",
        "100123456700003",
        "50 123 4567",
        "Office 12",
        "Dubai"
      ]

      [result] = Import.classify([values], mapping, "vat", [])

      assert result.status == :ready
      assert result.attrs["country"] == "AE"
      assert result.attrs["phone_country_code"] == "+971"
      assert result.attrs["client_type"] == "Registered Business"
    end

    test "checks the tax number for its country" do
      mapping = Import.suggest_mapping(@vat_headers, [])
      values = ["Gulf Trading LLC", "AE", "12", "501234567", "Office 12", "Dubai"]

      [result] = Import.classify([values], mapping, "vat", [])

      assert result.status == :invalid
      assert Enum.any?(result.errors, &String.starts_with?(&1, "Tax number"))
    end

    test "imports the ready rows" do
      mapping = Import.suggest_mapping(@vat_headers, [])
      values = ["Gulf Trading LLC", "AE", "100123456700003", "501234567", "Office 12", "Dubai"]
      [%{status: :ready, attrs: attrs}] = Import.classify([values], mapping, "vat", [])

      assert {:ok, [client]} = Clients.import_clients([attrs])
      assert client.tax_number == "100123456700003"
      assert client.country == "AE"
    end
  end

  describe "Clients.import_clients/2" do
    test "inserts every row, announces it once and audits it" do
      Events.subscribe(Events.clients_topic())

      ready =
        for %{status: :ready, attrs: attrs} <- classify([row(), row(%{name: "Beta Co"})]),
            do: attrs

      assert {:ok, clients} = Clients.import_clients(ready, file: "clients.csv")
      assert Enum.map(clients, & &1.name) |> Enum.sort() == ["Acme Traders", "Beta Co"]
      assert_receive {:clients_imported, 2}

      saved = Clients.get_client!(hd(clients).id)
      assert saved.billing_state == "Tamil Nadu (33)"
      assert saved.shipping_same_as_billing
    end

    test "inserts nothing when any row fails" do
      good = hd(classify([row()])).attrs
      bad = Map.put(good, "name", "") |> Map.put("phone", "9000000009")

      assert {:error, %Ecto.Changeset{}} = Clients.import_clients([good, bad])
      assert [%{status: :ready}] = classify([row()])
    end

    test "an empty list is a no-op" do
      assert {:ok, []} = Clients.import_clients([])
    end
  end
end
