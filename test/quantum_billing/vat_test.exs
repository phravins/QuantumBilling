defmodule QuantumBilling.VATTest do
  @moduledoc """
  VAT: totals by rate, tax-inclusive prices, rate snapshots on invoices, the
  owner-only rate list, and how VAT reaches credit notes, reports and clients.
  """
  # Not async: the isolation test builds a business schema.
  use QuantumBilling.DataCase, async: false

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit
  alias QuantumBilling.Businesses
  alias QuantumBilling.Clients
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Reports
  alias QuantumBilling.Settings
  alias QuantumBilling.Tax.VAT
  alias QuantumBilling.TaxRates

  @trn "100123456700003"

  defp scope_for(user) do
    business = Businesses.default!()
    Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))
  end

  setup do
    owner = owner_fixture()
    %{owner_user: owner, owner: scope_for(owner), staff: scope_for(user_fixture())}
  end

  defp switch_to_vat(attrs \\ %{}) do
    {:ok, organization} =
      Settings.update_section(
        Settings.get_organization(),
        Map.merge(%{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => @trn}, attrs),
        :tax
      )

    organization
  end

  defp vat_business(%{owner: owner}) do
    switch_to_vat()
    {:ok, _rates} = TaxRates.ensure_presets(owner, "AE")
    :ok
  end

  defp rate(name), do: Enum.find(TaxRates.list_rates(archived: :include), &(&1.name == name))

  # `amount` is in major units, as the form and API send it.
  defp line(rate, amount) do
    %{
      "description" => "Line",
      "quantity" => "1",
      "unit" => "Nos",
      "rate" => amount,
      "tax_rate_id" => rate && to_string(rate.id)
    }
  end

  defp invoice_attrs(lines, attrs \\ %{}) do
    items =
      lines
      |> Enum.with_index()
      |> Map.new(fn {line, index} ->
        {to_string(index), Map.put(line, "position", to_string(index))}
      end)

    Map.merge(
      %{
        "invoice_type" => "Tax Invoice",
        "invoice_date" => Date.to_iso8601(Date.utc_today()),
        "client_name" => "Gulf Trading LLC",
        "items" => items
      },
      attrs
    )
  end

  defp create_invoice!(lines, attrs \\ %{}) do
    {:ok, invoice} = lines |> invoice_attrs(attrs) |> Invoices.create_invoice()
    invoice
  end

  @client %{
    "client_type" => "Registered Business",
    "name" => "Gulf Trading LLC",
    "phone" => "501234567",
    "phone_country_code" => "+971",
    "billing_line1" => "Office 12, Al Quoz",
    "billing_city" => "Dubai",
    "country" => "AE"
  }

  defp item(amount, rate_bp, category \\ "standard", name \\ nil) do
    %InvoiceItem{
      quantity: Decimal.new(1),
      rate: amount,
      tax_rate_bp: rate_bp,
      tax_category: category,
      tax_name: name || "Rate #{rate_bp}"
    }
  end

  describe "VAT.totals/2" do
    test "taxes each rate's total once, so the summary adds up" do
      # Three 0.10 lines at 5%: per line each rounds up to 0.01, but the group
      # owes 0.015, which rounds to 0.02.
      items = for _ <- 1..3, do: item(10, 500, "standard", "Standard 5%")
      totals = VAT.totals(items)

      assert totals.taxable_value == 30
      assert totals.vat_amount == 2
      assert totals.grand_total == 32
      assert totals.round_off == 0

      assert [%{"name" => "Standard 5%", "rate_bp" => 500, "taxable" => 30, "tax" => 2}] =
               totals.tax_breakdown
    end

    test "mixed rates give one row each, highest first, and untaxed rows carry no tax" do
      items = [
        item(50_000, 0, "zero", "Zero-rated"),
        item(100_000, 500, "standard", "Standard 5%"),
        item(20_000, 0, "exempt", "Exempt"),
        item(10_000, 750, "reduced", "Hotel")
      ]

      totals = VAT.totals(items)

      assert Enum.map(totals.tax_breakdown, &{&1["name"], &1["taxable"], &1["tax"]}) == [
               {"Hotel", 10_000, 750},
               {"Standard 5%", 100_000, 5_000},
               {"Exempt", 20_000, 0},
               {"Zero-rated", 50_000, 0}
             ]

      assert totals.vat_amount == 5_750
      assert totals.taxable_value == 180_000
      assert totals.grand_total == 185_750
      assert totals.cgst_amount == 0 and totals.igst_amount == 0
    end

    test "an exempt line is untaxed even if its rate says otherwise" do
      assert VAT.totals([item(10_000, 500, "exempt")]).vat_amount == 0
    end

    test "tax-inclusive prices take the VAT out of the price" do
      totals = VAT.totals([item(105_000, 500)], %{prices_include_tax: true})

      assert totals.taxable_value == 100_000
      assert totals.vat_amount == 5_000
      assert totals.grand_total == 105_000
    end

    test "reverse charge puts every line in one untaxed row" do
      totals =
        VAT.totals([item(100_000, 500), item(10_000, 750)], %{reverse_charge: true})

      assert totals.vat_amount == 0
      assert totals.grand_total == 110_000

      assert [%{"name" => "Reverse charge", "category" => "reverse_charge", "tax" => 0}] =
               totals.tax_breakdown
    end

    test "rounds to whole units only when asked" do
      items = [item(100_010, 500)]

      assert %{grand_total: 105_011, round_off: 0} = VAT.totals(items)

      assert %{grand_total: 105_000, round_off: -11} =
               VAT.totals(items, %{round_to_whole_units: true})
    end
  end

  describe "VAT invoices" do
    setup :vat_business

    test "snapshot the business's regime and each line's rate" do
      standard = rate("Standard 5%")

      invoice =
        create_invoice!([line(standard, "1000"), line(rate("Zero-rated"), "500")], %{
          "client_tax_number" => "100 2003 0040 0003"
        })

      assert invoice.tax_regime == "vat"
      assert invoice.company_tax_number == @trn
      assert invoice.client_tax_number == "100200300400003"
      assert invoice.taxable_value == 150_000
      assert invoice.vat_amount == 5_000
      assert invoice.round_off == 0
      assert invoice.grand_total == 155_000
      assert invoice.cgst_amount == 0 and invoice.igst_amount == 0
      assert length(invoice.tax_breakdown) == 2

      [first, second] = Enum.sort_by(invoice.items, & &1.position)
      assert %{tax_rate_id: id, tax_rate_bp: 500, tax_name: "Standard 5%"} = first
      assert id == standard.id
      assert %{tax_rate_bp: 0, tax_category: "zero"} = second
    end

    test "a line sent without a rate takes the default one" do
      invoice = create_invoice!([line(nil, "200")])

      assert [%{tax_rate_id: id, tax_rate_bp: 500}] = invoice.items
      assert id == TaxRates.default_rate().id
      assert invoice.vat_amount == 1_000
    end

    test "place of supply is not needed", %{} do
      invoice = create_invoice!([line(rate("Standard 5%"), "100")])
      assert invoice.place_of_supply in [nil, ""]
    end

    test "an archived rate cannot be picked for a new line", %{owner: owner} do
      exempt = rate("Exempt")
      {:ok, _} = TaxRates.archive_rate(owner, exempt)

      assert {:error, changeset} =
               [line(exempt, "100")] |> invoice_attrs() |> Invoices.create_invoice()

      [item_changeset] = changeset.changes.items
      assert "is archived; choose another rate" in errors_on(item_changeset).tax_rate_id
    end

    test "editing or archiving a rate leaves issued invoices alone", %{owner: owner} do
      standard = rate("Standard 5%")
      invoice = create_invoice!([line(standard, "1000")])

      {:ok, _} = TaxRates.update_rate(owner, standard, %{"percent" => "6"})
      {:ok, _} = TaxRates.archive_rate(owner, rate("Standard 5%"))

      invoice = Invoices.get_invoice!(invoice.id)
      [stored] = invoice.items

      {:ok, updated} =
        Invoices.update_invoice(invoice, %{
          "remarks" => "Edited after the rate changed",
          "items" => %{
            "0" => %{"id" => to_string(stored.id), "description" => "Renamed line"}
          }
        })

      assert [%{tax_rate_bp: 500, description: "Renamed line"}] = updated.items
      assert updated.vat_amount == 5_000
    end

    test "a reverse-charge invoice charges no VAT" do
      invoice =
        create_invoice!([line(rate("Standard 5%"), "1000")], %{"reverse_charge" => "true"})

      assert invoice.reverse_charge
      assert invoice.vat_amount == 0
      assert invoice.grand_total == 100_000
      assert [%{"name" => "Reverse charge"}] = invoice.tax_breakdown
    end

    test "tax-inclusive pricing comes from the business" do
      switch_to_vat(%{"prices_include_tax" => "true"})
      invoice = create_invoice!([line(rate("Standard 5%"), "1050")])

      assert invoice.prices_include_tax
      assert invoice.taxable_value == 100_000
      assert invoice.vat_amount == 5_000
      assert invoice.grand_total == 105_000
    end

    test "a credit note splits its tax by the invoice's rates" do
      {:ok, client} = Clients.create_client(Map.put(@client, "tax_number", @trn))

      invoice =
        create_invoice!(
          [line(rate("Standard 5%"), "1000"), line(rate("Zero-rated"), "500")],
          %{"client_id" => to_string(client.id)}
        )

      {:ok, note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "subtotal" => "750",
          "tax_total" => "25",
          "grand_total" => "775"
        })

      assert note.tax_regime == "vat"
      assert note.tax_breakdown |> Enum.map(& &1["tax"]) |> Enum.sum() == 2_500
      assert note.tax_breakdown |> Enum.map(& &1["taxable"]) |> Enum.sum() == 75_000
    end

    test "reports show VAT by rate" do
      create_invoice!([line(rate("Standard 5%"), "1000"), line(rate("Zero-rated"), "500")])

      rows = Reports.tax_rows(%{})
      standard = Enum.find(rows, &(&1.label == "VAT · Standard 5%"))

      assert %{taxable_value: 100_000, vat: 5_000, total_tax: 5_000} = standard
      assert Enum.find(rows, &(&1.label == "VAT · Zero-rated")).total_tax == 0
      assert List.last(rows).total_tax == 5_000
    end

    test "a VAT client needs a valid number for its country, not a GSTIN" do
      assert {:error, changeset} = Clients.create_client(Map.put(@client, "tax_number", "12"))
      assert errors_on(changeset)[:tax_number]

      assert {:ok, client} = Clients.create_client(Map.put(@client, "tax_number", @trn))
      assert client.tax_number == @trn
      assert is_nil(client.gstin)
    end
  end

  describe "regime changes" do
    test "invoices raised under GST stay GST after the switch to VAT", %{owner: owner} do
      {:ok, gst} =
        Invoices.create_invoice(%{
          "invoice_type" => "Tax Invoice",
          "invoice_date" => Date.to_iso8601(Date.utc_today()),
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "V2V Technologies",
          "items" => %{
            "0" => %{
              "description" => "Consulting",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "1000",
              "tax_rate" => "18"
            }
          }
        })

      switch_to_vat()
      {:ok, _rates} = TaxRates.ensure_presets(owner, "AE")

      gst = Invoices.get_invoice!(gst.id)
      {:ok, updated} = Invoices.update_invoice(gst, %{"remarks" => "After the switch"})

      assert updated.tax_regime == "gst"
      assert updated.vat_amount == 0
      assert updated.cgst_amount + updated.sgst_amount + updated.igst_amount == 18_000
      assert [%{tax_rate: 18, tax_rate_bp: nil}] = updated.items
    end
  end

  describe "tax rates" do
    setup :vat_business

    test "only owners change them", %{staff: staff} do
      standard = rate("Standard 5%")

      assert {:error, :unauthorized} =
               TaxRates.create_rate(staff, %{"name" => "X", "category" => "zero"})

      assert {:error, :unauthorized} = TaxRates.update_rate(staff, standard, %{"percent" => "9"})
      assert {:error, :unauthorized} = TaxRates.archive_rate(staff, standard)
      assert {:error, :unauthorized} = TaxRates.set_default(staff, rate("Zero-rated"))
      assert {:error, :unauthorized} = TaxRates.ensure_presets(staff, "GB")
      assert rate("Standard 5%").rate_bp == 500
    end

    test "every change is audited", %{owner: owner} do
      {:ok, hotel} =
        TaxRates.create_rate(owner, %{
          "name" => "Hotel",
          "category" => "reduced",
          "percent" => "7.5"
        })

      {:ok, _} = TaxRates.set_default(owner, hotel)
      {:ok, hotel} = TaxRates.archive_rate(owner, hotel)
      {:ok, _} = TaxRates.restore_rate(owner, hotel)

      actions = Enum.map(Audit.list_audit_logs(), & &1.action)

      for action <- ~w(tax_rates_preset_added tax_rate_created tax_rate_default_set
                       tax_rate_archived tax_rate_restored) do
        assert action in actions
      end
    end

    test "an archived rate cannot be the default", %{owner: owner} do
      {:ok, archived} = TaxRates.archive_rate(owner, rate("Zero-rated"))
      assert {:error, :archived} = TaxRates.set_default(owner, archived)
    end

    test "presets are added only to an empty list", %{owner: owner} do
      {:ok, _rates} = TaxRates.ensure_presets(owner, "GB")
      assert Enum.map(TaxRates.list_rates(), & &1.name) |> Enum.member?("Standard 5%")
      refute Enum.any?(TaxRates.list_rates(), &(&1.name == "Standard 20%"))
    end

    test "at most 50 are active at once", %{owner: owner} do
      for n <- 1..46 do
        {:ok, _} = TaxRates.create_rate(owner, %{"name" => "Rate #{n}", "category" => "zero"})
      end

      assert {:error, :limit_reached} =
               TaxRates.create_rate(owner, %{"name" => "One too many", "category" => "zero"})
    end

    test "stay inside their own business", %{owner_user: owner_user} do
      {:ok, other} = Businesses.create(owner_user, %{"name" => "Firm Two"})

      assert Repo.with_business(other, fn -> TaxRates.list_rates(archived: :include) end) == []
      assert length(TaxRates.list_rates()) == 4
    end
  end
end
