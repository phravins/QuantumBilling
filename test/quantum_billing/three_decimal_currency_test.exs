defmodule QuantumBilling.ThreeDecimalCurrencyTest do
  @moduledoc """
  KWD, BHD and OMR (issue #23): amounts are stored as fils or baisa, 1000 to
  the unit, and survive every path a two-decimal amount takes: forms,
  rounding, credit notes, conversion, custom fields, documents and webhooks.
  They need the VAT regime, and the business currency can't move between two
  and three decimals once there are records.
  """
  # Not async: the webhook test swaps Req's global default options.
  use QuantumBilling.DataCase, async: false

  import QuantumBilling.AccountsFixtures
  import QuantumBilling.CustomFieldsFixtures, only: [field_fixture: 3, owner_scope: 1]

  alias QuantumBilling.ApiFixtures
  alias QuantumBilling.Clients
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Currency
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Invoices
  alias QuantumBilling.Quotations
  alias QuantumBilling.Settings
  alias QuantumBilling.TaxRates
  alias QuantumBilling.Webhooks.Endpoint
  alias QuantumBillingWeb.InvoicePdfGenerator

  @bahrain_vat "200000000000003"

  @places_error "can't move between two- and three-decimal currencies once you have " <>
                  "clients, documents or default amounts on custom fields"

  @client %{
    "client_type" => "Registered Business",
    "name" => "Gulf Trading LLC",
    "phone" => "501234567",
    "phone_country_code" => "+971",
    "billing_line1" => "Office 12, Al Quoz",
    "billing_city" => "Dubai",
    "country" => "AE"
  }

  setup do
    owner = owner_fixture()
    %{owner: owner_scope(owner)}
  end

  defp save(section, attrs),
    do: Settings.update_section(Settings.get_organization(), attrs, section)

  defp general(currency),
    do: %{"company_name" => "Manama Traders", "currency" => Currency.label(currency)}

  # A Bahraini business billing in BHD at 10% VAT.
  defp bhd_business(%{owner: owner}, tax \\ %{}) do
    {:ok, _} =
      save(
        :tax,
        Map.merge(
          %{"tax_regime" => "vat", "vat_country" => "BH", "vat_number" => @bahrain_vat},
          tax
        )
      )

    {:ok, _} = save(:general, general("BHD"))
    {:ok, _rates} = TaxRates.ensure_presets(owner, "BH")
    :ok
  end

  defp standard_rate, do: Enum.find(TaxRates.list_rates(), &(&1.name == "Standard 10%"))

  defp line(rate, quantity \\ "2.5") do
    %{
      "description" => "Steel fittings",
      "quantity" => quantity,
      "unit" => "Nos",
      "rate" => rate,
      "tax_rate_id" => to_string(standard_rate().id),
      "position" => "0"
    }
  end

  defp invoice_attrs(over) do
    Map.merge(
      %{
        "invoice_type" => "Tax Invoice",
        "invoice_date" => Date.to_iso8601(Date.utc_today()),
        "client_name" => "Gulf Trading LLC",
        "items" => %{"0" => line("12.345")}
      },
      over
    )
  end

  defp create_invoice!(over \\ %{}) do
    {:ok, invoice} = over |> invoice_attrs() |> Invoices.create_invoice()
    Invoices.get_invoice!(invoice.id)
  end

  describe "a BHD invoice" do
    setup :bhd_business

    test "keeps the rate to the fils and taxes it in fils" do
      invoice = create_invoice!()

      assert invoice.currency == "BHD"
      assert [%{rate: 12_345, amount: 30_863}] = invoice.items
      # 12.345 × 2.5 = 30.8625, half-up to 30.863; 10% VAT is 3.086.
      assert invoice.taxable_value == 30_863
      assert invoice.vat_amount == 3_086
      assert invoice.grand_total == 33_949
      assert invoice.round_off == 0
    end

    test "refuses a fourth decimal place" do
      assert {:error, changeset} =
               Invoices.create_invoice(invoice_attrs(%{"items" => %{"0" => line("12.3456")}}))

      assert [%{rate: ["must be an amount with at most three decimal places"]}] =
               errors_on(changeset).items
    end

    test "the document shows three decimals and the fils in words" do
      html = InvoicePdfGenerator.generate_html(create_invoice!(), print_button: false)

      assert html =~ "12.345"
      assert html =~ "BHD 33.949"
      assert html =~ "Nine Hundred Forty Nine Fils"
    end

    test "a saved invoice keeps its currency" do
      invoice = create_invoice!()

      assert {:error, changeset} = Invoices.update_invoice(invoice, %{"currency" => "AED"})
      assert %{currency: [_message]} = errors_on(changeset)
      assert Invoices.get_invoice!(invoice.id).currency == "BHD"
    end
  end

  describe "rounding to whole dinars" do
    setup context do
      bhd_business(context, %{"round_to_whole_units" => "true"})
    end

    test "rounds the total at 1000 fils" do
      invoice = create_invoice!()

      assert invoice.grand_total == 34_000
      assert invoice.round_off == 51
    end

    test "tax-inclusive prices split the gross in fils" do
      {:ok, _} = save(:tax, %{"prices_include_tax" => "true", "round_to_whole_units" => "false"})
      invoice = create_invoice!()

      # 30.863 gross at 10%: 28.057 net and 2.806 VAT.
      assert invoice.taxable_value == 28_057
      assert invoice.vat_amount == 2_806
      assert invoice.grand_total == 30_863
    end

    test "invoice.created sends whole dinars, as it sends whole rupees" do
      previous = Req.default_options()
      Req.default_options(plug: {Req.Test, __MODULE__})
      on_exit(fn -> Req.default_options(previous) end)
      Req.Test.set_req_test_to_shared()
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:received, body})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      Repo.insert!(%Endpoint{
        url: "https://old.example.test/hooks",
        events: ["invoice.created"],
        format: "legacy",
        secret: "whsec_old"
      })

      create_invoice!()

      assert_received {:received, body}
      assert %{"payload" => %{"grand_total" => 34}} = Jason.decode!(body)
    end
  end

  describe "a BHD credit note" do
    setup :bhd_business

    defp invoice_for_client! do
      {:ok, client} = Clients.create_client(@client)
      create_invoice!(%{"client_id" => to_string(client.id)})
    end

    test "splits its total in fils, in the invoice's proportion" do
      invoice = invoice_for_client!()

      assert {:ok, note} =
               CreditNotes.create_credit_note_for_invoice(invoice, %{"grand_total" => "11.000"})

      assert note.grand_total == 11_000
      assert note.subtotal + note.tax_total == 11_000
      assert note.subtotal == 10_000
    end

    test "defaults to what is left and refuses more, to the fils" do
      invoice = invoice_for_client!()

      assert {:error, changeset} =
               CreditNotes.create_credit_note_for_invoice(invoice, %{"grand_total" => "33.950"})

      assert %{grand_total: [message]} = errors_on(changeset)
      assert message =~ "33.949"

      assert {:error, changeset} =
               CreditNotes.create_credit_note_for_invoice(invoice, %{"grand_total" => "1.2345"})

      assert %{grand_total: ["must be an amount with at most three decimal places"]} =
               errors_on(changeset)

      assert {:ok, note} = CreditNotes.create_credit_note_for_invoice(invoice)
      assert note.grand_total == 33_949
    end
  end

  describe "a BHD quotation" do
    setup :bhd_business

    test "converts into an invoice with the same fils", %{owner: owner} do
      today = Quotations.today()

      {:ok, quotation} =
        Quotations.create_quotation(owner, %{
          "quotation_date" => Date.to_iso8601(today),
          "valid_until" => Date.to_iso8601(Date.add(today, 30)),
          "client_name" => "Gulf Trading LLC",
          "items" => %{"0" => line("12.345", "3")}
        })

      assert quotation.currency == "BHD"
      assert [%{rate: 12_345}] = Repo.preload(quotation, :items).items

      {:ok, quotation} = Quotations.accept(owner, quotation)

      params =
        quotation
        |> Quotations.invoice_params()
        |> Map.put("invoice_date", Date.to_iso8601(today))

      assert {:ok, invoice} = Invoices.create_invoice(params, quotation_id: quotation.id)

      invoice = Invoices.get_invoice!(invoice.id)
      assert invoice.currency == "BHD"
      assert [%{rate: 12_345, amount: 37_035}] = invoice.items
      assert invoice.grand_total == quotation.grand_total
    end
  end

  describe "BHD amounts outside documents" do
    setup :bhd_business

    test "money custom fields take the record's three decimals", %{owner: owner} do
      field_fixture("invoice", %{"label" => "Deposit", "type" => "money"}, owner)
      field_fixture("client", %{"label" => "Limit", "type" => "money"}, owner)

      invoice = create_invoice!(%{"custom_fields" => %{"deposit" => "1.250"}})
      assert invoice.custom_fields["deposit"] == 1_250

      assert {:error, changeset} =
               Invoices.create_invoice(
                 invoice_attrs(%{"custom_fields" => %{"deposit" => "1.2345"}})
               )

      assert %{custom_fields: [_message]} = errors_on(changeset)

      {:ok, client} =
        Clients.create_client(
          Map.merge(@client, %{
            "credit_limit" => "100.500",
            "opening_balance" => "2.005",
            "custom_fields" => %{"limit" => "5.125"}
          })
        )

      assert client.credit_limit == 100_500
      assert client.opening_balance == 2_005
      assert client.custom_fields["limit"] == 5_125
    end
  end

  describe "choosing a three-decimal currency" do
    test "needs the VAT regime" do
      assert {:error, changeset} = save(:general, general("KWD"))
      assert "KWD needs the VAT tax regime" in errors_on(changeset).currency
    end

    test "keeps the regime at VAT while it's in use", context do
      bhd_business(context)

      assert {:error, changeset} = save(:tax, %{"tax_regime" => "gst"})
      assert "must be VAT while the business bills in BHD" in errors_on(changeset).tax_regime
    end

    test "is allowed while the business has no records" do
      {:ok, _} =
        save(:tax, %{"tax_regime" => "vat", "vat_country" => "BH", "vat_number" => @bahrain_vat})

      assert {:ok, organization} = save(:general, general("KWD"))
      assert Settings.Organization.currency_code(organization) == "KWD"
    end

    test "is refused once there is a client, which would be read ten times smaller" do
      ApiFixtures.client_fixture()

      {:ok, _} =
        save(:tax, %{"tax_regime" => "vat", "vat_country" => "BH", "vat_number" => @bahrain_vat})

      assert {:error, changeset} = save(:general, general("BHD"))
      assert @places_error in errors_on(changeset).currency

      # The same number of decimals is still fine.
      assert {:ok, _} = save(:general, general("AED"))
    end

    test "is refused while a money custom field has a default, which would be read ten times smaller",
         %{owner: owner} do
      definition =
        field_fixture(
          "client",
          %{"label" => "Deposit", "type" => "money", "default" => "100.00"},
          owner
        )

      {:ok, _} =
        save(:tax, %{"tax_regime" => "vat", "vat_country" => "BH", "vat_number" => @bahrain_vat})

      assert {:error, changeset} = save(:general, general("BHD"))
      assert @places_error in errors_on(changeset).currency
      assert Settings.currency_code() == "INR"
      assert CustomFields.get_definition!(definition.id).options["default"] == 10_000

      # A money field without a default holds nothing to misread.
      {:ok, _} =
        CustomFields.update_definition(owner, definition, %{"default" => ""})

      assert {:ok, _} = save(:general, general("BHD"))
    end

    test "a GST invoice can't be in one" do
      assert {:error, changeset} =
               Invoices.create_invoice(%{
                 "invoice_type" => "Tax Invoice",
                 "invoice_date" => Date.to_iso8601(Date.utc_today()),
                 "client_name" => "Acme",
                 "place_of_supply" => "Maharashtra (27)",
                 "currency" => "KWD",
                 "items" => %{
                   "0" => %{
                     "description" => "Work",
                     "quantity" => "1",
                     "unit" => "Nos",
                     "rate" => "10",
                     "tax_rate" => "18",
                     "position" => "0"
                   }
                 }
               })

      assert %{currency: [_message]} = errors_on(changeset)
    end
  end
end
