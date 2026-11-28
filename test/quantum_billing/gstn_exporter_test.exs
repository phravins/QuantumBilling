defmodule QuantumBilling.GSTNExporterTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Compliance.GSTNExporter
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem

  defp invoice(attrs) do
    defaults = %{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra (27)",
      company_state: "Maharashtra (27)",
      client_name: "Delta Retailers",
      client_gstin: "27CCCDE1234F1Z5",
      taxable_value: 5_000_000,
      cgst_amount: 450_000,
      sgst_amount: 450_000,
      grand_total: 5_900_000
    }

    Repo.insert!(struct(%Invoice{}, Map.merge(defaults, attrs)))
  end

  defp item(invoice, attrs) do
    defaults = %{
      invoice_id: invoice.id,
      description: "Consulting",
      hsn_sac: "998313",
      quantity: 1,
      unit: "Nos",
      rate: 1_000_000,
      tax_rate: 18,
      amount: 1_000_000,
      position: 0
    }

    Repo.insert!(struct(%InvoiceItem{}, Map.merge(defaults, attrs)))
  end

  describe "validate_period/1" do
    test "accepts MMYYYY and rejects everything else" do
      assert {:ok, %{period: "032026", month: 3, year: 2026}} =
               GSTNExporter.validate_period("032026")

      assert {:error, _} = GSTNExporter.validate_period("132026")
      assert {:error, _} = GSTNExporter.validate_period("002026")
      assert {:error, _} = GSTNExporter.validate_period("3-2026")
      assert {:error, _} = GSTNExporter.validate_period("2026")
      assert {:error, _} = GSTNExporter.validate_period(nil)

      # The period reaches a filename and a query. Neither may take this.
      assert {:error, _} = GSTNExporter.validate_period("032026'; DROP TABLE invoices;--")
    end
  end

  describe "default_period/1" do
    test "is the month just gone, including across a year boundary" do
      assert GSTNExporter.default_period(~D[2026-03-16]) == "022026"
      assert GSTNExporter.default_period(~D[2026-01-04]) == "122025"
    end
  end

  describe "generate_gstr1_json/1" do
    test "reports exports separately and converts foreign currency to INR" do
      export =
        invoice(%{
          invoice_number: "EXPORT-1",
          client_gstin: nil,
          export_type: "EXPORT_WITH_PAY",
          currency: "USD",
          exchange_rate: Decimal.new("80"),
          place_of_supply: "Other Countries (96)",
          taxable_value: 100_000,
          cgst_amount: 0,
          sgst_amount: 0,
          igst_amount: 18_000,
          grand_total: 118_000
        })

      item(export, %{amount: 100_000, rate: 100_000})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")
      assert [%{"exp_typ" => "WPAY", "inv" => [entry]}] = json["exp"]
      assert entry["inum"] == "EXPORT-1"
      assert entry["val"] == 94_400.0
      assert [%{"txval" => 80_000.0, "iamt" => 14_400.0}] = entry["itms"]
      assert json["b2cl"] == []
      assert json["b2cs"] == []
      assert [%{"txval" => 80_000.0}] = json["hsn"]["hsn_b2c"]
    end

    test "reports an export without payment and its credit note in export sections" do
      export =
        invoice(%{
          invoice_number: "EXPORT-LUT",
          client_gstin: nil,
          export_type: "EXPORT_WITHOUT_PAY",
          place_of_supply: "Other Countries (96)",
          taxable_value: 100_000,
          cgst_amount: 0,
          sgst_amount: 0,
          igst_amount: 0,
          grand_total: 100_000
        })

      item(export, %{amount: 100_000, rate: 100_000, tax_rate: 18})
      note(export, %{subtotal: 50_000, tax_total: 0, grand_total: 50_000})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"exp_typ" => "WOPAY", "inv" => [%{"itms" => [line]}]}] =
               json["exp"]

      assert line["iamt"] == 0
      assert [%{"typ" => "EXPWOP", "ntty" => "C", "val" => 500.0}] = json["cdnur"]
      assert [%{"txval" => 500.0}] = json["hsn"]["hsn_b2c"]
      assert json["b2cs"] == []
      assert json["b2cl"] == []
    end

    test "constructs the GSTN structure for the period" do
      invoice = invoice(%{invoice_number: "INV-9904"})
      item(invoice, %{})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert json["version"] == "GSTR1_v3.1"
      assert json["fp"] == "032026"
      assert is_list(json["b2b"])
      assert is_list(json["b2cs"])
      assert is_map(json["hsn"])
    end

    # A demo IRN was never registered; the government has no record of it.
    test "leaves a demo IRN out and keeps one the IRP registered" do
      demo = invoice(%{irn: String.duplicate("d", 64), irn_mode: "demo"})
      item(demo, %{})
      live = invoice(%{irn: String.duplicate("e", 64), irn_mode: "live"})
      item(live, %{})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      entries = json["b2b"] |> Enum.flat_map(& &1["inv"])
      by_number = Map.new(entries, &{&1["inum"], &1})

      refute Map.has_key?(by_number[demo.invoice_number], "irn")
      assert by_number[live.invoice_number]["irn"] == live.irn
    end

    test "refuses a period it cannot parse" do
      assert {:error, message} = GSTNExporter.generate_gstr1_json("nonsense")
      assert message =~ "MMYYYY"
    end

    test "reports only the invoices dated in the period" do
      invoice(%{invoice_number: "IN-PERIOD", invoice_date: ~D[2026-03-31]})
      invoice(%{invoice_number: "MONTH-BEFORE", invoice_date: ~D[2026-02-28]})
      invoice(%{invoice_number: "MONTH-AFTER", invoice_date: ~D[2026-04-01]})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      numbers = for party <- json["b2b"], inv <- party["inv"], do: inv["inum"]

      # Only invoices dated in the period belong in its return.
      assert numbers == ["IN-PERIOD"]
    end

    test "leaves cancelled invoices out" do
      invoice(%{invoice_number: "LIVE-ONE"})
      invoice(%{invoice_number: "CANCELLED-ONE", status: "Cancelled"})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      numbers = for party <- json["b2b"], inv <- party["inv"], do: inv["inum"]

      assert numbers == ["LIVE-ONE"]
    end

    test "reports each rate on a mixed invoice separately" do
      # 5% on the goods, 18% on the service: 500 + 1,800 of tax, split
      # CGST/SGST because supply and company share a state.
      invoice =
        invoice(%{
          invoice_number: "MIXED-RATES",
          taxable_value: 2_000_000,
          cgst_amount: 115_000,
          sgst_amount: 115_000,
          grand_total: 2_230_000
        })

      item(invoice, %{description: "Goods", hsn_sac: "1001", tax_rate: 5, position: 0})
      item(invoice, %{description: "Service", hsn_sac: "998313", tax_rate: 18, position: 1})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      [%{"inv" => [entry]}] = json["b2b"]

      rates = entry["itms"] |> Enum.map(& &1["itm_det"]["rt"]) |> Enum.sort()

      assert rates == [5.0, 18.0]

      assert Enum.sum(Enum.map(entry["itms"], & &1["itm_det"]["txval"])) == 20_000
      assert Enum.sum(Enum.map(entry["itms"], & &1["itm_det"]["camt"])) == 1_150
    end

    test "summarises HSN by code without raising on the field name" do
      invoice = invoice(%{invoice_number: "HSN-ONE"})
      item(invoice, %{hsn_sac: "998313", tax_rate: 18})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"hsn_sc" => "998313"} = row] = json["hsn"]["hsn_b2b"]
      assert row["txval"] == 10_000
      assert json["hsn"]["hsn_b2c"] == []
    end

    test "puts a large inter-state consumer sale in b2cl, not b2cs" do
      invoice(%{
        invoice_number: "BIG-B2C",
        client_gstin: nil,
        place_of_supply: "Karnataka (29)",
        company_state: "Maharashtra (27)",
        taxable_value: 30_000_000,
        cgst_amount: 0,
        sgst_amount: 0,
        igst_amount: 5_400_000,
        grand_total: 35_400_000
      })

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"pos" => "29", "inv" => [%{"inum" => "BIG-B2C"}]}] = json["b2cl"]
      assert json["b2b"] == []
    end

    test "summarises small consumer sales in b2cs" do
      invoice(%{
        invoice_number: "SMALL-B2C",
        client_gstin: nil,
        taxable_value: 100_000,
        cgst_amount: 9_000,
        sgst_amount: 9_000,
        grand_total: 118_000
      })

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"typ" => "OE", "pos" => "27", "txval" => 1_000.0}] = json["b2cs"]
      assert json["b2cl"] == []
    end

    # 00:30 IST on 1 December is 19:00 UTC on 30 November: the note belongs to
    # December's return, under its own number and date.
    test "reports a note in the month of its IST date, not its UTC save time" do
      client = Repo.insert!(%Client{name: "Delta Retailers", email: "delta@example.com"})

      invoice =
        invoice(%{invoice_number: "INV-0042", invoice_date: ~D[2026-11-20], client_id: client.id})

      Repo.insert!(%CreditNote{
        note_number: "CN-0001",
        note_date: ~D[2026-12-01],
        note_type: "Credit",
        reason: "Rate revised",
        grand_total: 118_000,
        invoice_id: invoice.id,
        client_id: client.id,
        inserted_at: ~U[2026-11-30 19:00:00Z],
        updated_at: ~U[2026-11-30 19:00:00Z]
      })

      assert {:ok, december} = GSTNExporter.generate_gstr1_json("122026")

      assert [%{"ctin" => "27CCCDE1234F1Z5", "nt" => [note]}] = december["cdnr"]
      assert note["nt_num"] == "CN-0001"
      assert note["nt_dt"] == "01-12-2026"
      assert note["ntty"] == "C"
      assert note["pos"] == "27"

      # Saved with only its total: split in the invoice's own proportion,
      # ₹50,000 + ₹9,000, so ₹1,000 + ₹180.
      assert [%{"itm_det" => %{"rt" => 18.0, "txval" => 1_000.0} = line}] = note["itms"]
      assert line["camt"] + line["samt"] == 180.0

      assert {:ok, november} = GSTNExporter.generate_gstr1_json("112026")
      assert november["cdnr"] == []
    end

    test "is empty, not broken, for a month with nothing in it" do
      invoice(%{invoice_date: ~D[2026-03-01]})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("072026")

      assert json["b2b"] == []
      assert json["b2cl"] == []
      assert json["b2cs"] == []
      assert json["cdnr"] == []
      assert json["cdnur"] == []
      assert json["hsn"] == %{"hsn_b2b" => [], "hsn_b2c" => []}
      assert json["doc_issue"] == %{"doc_det" => []}
    end

    test "fills the tax heads on Table 12, CGST/SGST within the state" do
      invoice =
        invoice(%{
          taxable_value: 1_000_000,
          cgst_amount: 90_000,
          sgst_amount: 90_000,
          grand_total: 1_180_000
        })

      item(invoice, %{})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [row] = json["hsn"]["hsn_b2b"]
      assert row["camt"] == 900.0
      assert row["samt"] == 900.0
      assert row["iamt"] == 0.0
      assert row["val"] == 11_800.0
    end

    test "fills IGST on Table 12 for an inter-state consumer sale, under B2C" do
      invoice =
        invoice(%{
          client_gstin: nil,
          place_of_supply: "Karnataka (29)",
          taxable_value: 1_000_000,
          cgst_amount: 0,
          sgst_amount: 0,
          igst_amount: 180_000,
          grand_total: 1_180_000
        })

      item(invoice, %{})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert json["hsn"]["hsn_b2b"] == []
      assert [row] = json["hsn"]["hsn_b2c"]
      assert row["iamt"] == 1_800.0
      assert row["camt"] == 0.0
      # A service code reports no quantity.
      assert row["uqc"] == "NA"
      assert row["qty"] == 0
    end

    test "reports the quantity of goods on Table 12" do
      invoice = invoice(%{})
      item(invoice, %{hsn_sac: "1001", unit: "Kg", quantity: Decimal.new("2.5"), rate: 400_000})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"hsn_sc" => "1001", "uqc" => "KGS", "qty" => 2.5}] = json["hsn"]["hsn_b2b"]
    end

    test "adds Table 12 up to Tables 4, 5, 7 and 9B across a mixed month" do
      registered =
        invoice(%{
          taxable_value: 2_000_000,
          cgst_amount: 115_000,
          sgst_amount: 115_000,
          grand_total: 2_230_000
        })

      item(registered, %{hsn_sac: "1001", tax_rate: 5, position: 0})
      item(registered, %{tax_rate: 18, position: 1})
      note(registered, %{subtotal: 500_000, tax_total: 57_500, grand_total: 557_500})

      large = big_consumer_invoice(%{})
      item(large, %{rate: 15_000_000})

      small = small_consumer_invoice()
      item(small, %{rate: 100_000})
      note(small, %{subtotal: 30_000, tax_total: 5_400, grand_total: 35_400})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      details =
        for(party <- json["b2b"], inv <- party["inv"], line <- inv["itms"], do: line["itm_det"]) ++
          for(
            group <- json["b2cl"],
            inv <- group["inv"],
            line <- inv["itms"],
            do: line["itm_det"]
          ) ++
          json["b2cs"]

      credited =
        for party <- json["cdnr"], nt <- party["nt"], line <- nt["itms"], do: line["itm_det"]

      hsn = json["hsn"]["hsn_b2b"] ++ json["hsn"]["hsn_b2c"]

      for key <- ~w(txval iamt camt samt) do
        reported = total(details, key) - total(credited, key)
        assert total(hsn, key) == reported, "Table 12 #{key} does not add up"
      end

      # The note on the small sale was netted into Table 7, not given a row.
      assert [%{"txval" => 700.0}] = json["b2cs"]
    end

    test "gives a registered buyer's note its lines, adding up to the note exactly" do
      invoice =
        invoice(%{
          taxable_value: 2_000_000,
          cgst_amount: 115_000,
          sgst_amount: 115_000,
          grand_total: 2_230_000
        })

      item(invoice, %{hsn_sac: "1001", tax_rate: 5, position: 0})
      item(invoice, %{tax_rate: 18, position: 1})

      # A third of each: the scaled lines have paise to settle.
      note(invoice, %{subtotal: 666_667, tax_total: 76_667, grand_total: 743_334})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"nt" => [note]}] = json["cdnr"]
      assert note["pos"] == "27"
      assert note["rchrg"] == "N"
      assert note["inv_typ"] == "R"
      refute Map.has_key?(note, "inum")

      lines = Enum.map(note["itms"], & &1["itm_det"])
      assert Enum.map(lines, & &1["rt"]) == [5.0, 18.0]
      assert total(lines, "txval") == 666_667
      assert total(lines, "camt") + total(lines, "samt") == 76_667
      assert total(lines, "iamt") == 0
    end

    # The issue-note form sends only the total; the stored split then defaults
    # to the whole invoice's ₹50,000 + ₹9,000.
    test "takes a note's lines from its total when its stored split does not add up to it" do
      invoice = invoice(%{})
      note(invoice, %{subtotal: 5_000_000, tax_total: 900_000, grand_total: 1_180_000})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"nt" => [note]}] = json["cdnr"]
      assert note["val"] == 11_800.0
      assert [%{"itm_det" => %{"txval" => 10_000.0} = line}] = note["itms"]
      assert line["camt"] + line["samt"] == 1_800.0
    end

    test "reports a note on a large inter-state consumer invoice in cdnur" do
      invoice = big_consumer_invoice(%{})
      note(invoice, %{subtotal: 1_000_000, tax_total: 180_000, grand_total: 1_180_000})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert json["cdnr"] == []
      assert [entry] = json["cdnur"]
      assert entry["typ"] == "B2CL"
      assert entry["ntty"] == "C"
      assert entry["pos"] == "29"

      assert [%{"itm_det" => line}] = entry["itms"]
      assert line == %{"rt" => 18.0, "txval" => 10_000.0, "iamt" => 1_800.0, "csamt" => 0}
    end

    test "uses the B2CL limit in force for the invoice's date" do
      # ₹1.77 lakh: above the ₹1 lakh limit from August 2024, below the old ₹2.5 lakh.
      big_consumer_invoice(%{invoice_number: "NOW", invoice_date: ~D[2026-03-10]})
      big_consumer_invoice(%{invoice_number: "THEN", invoice_date: ~D[2024-03-10]})

      assert {:ok, now} = GSTNExporter.generate_gstr1_json("032026")
      assert [%{"inv" => [%{"inum" => "NOW"}]}] = now["b2cl"]
      assert now["b2cs"] == []

      assert {:ok, then} = GSTNExporter.generate_gstr1_json("032024")
      assert then["b2cl"] == []
      assert [%{"sply_ty" => "INTER", "pos" => "29"}] = then["b2cs"]
    end

    test "nets notes on small consumer sales into Table 7" do
      credited = small_consumer_invoice()
      item(credited, %{rate: 100_000})
      note(credited, %{subtotal: 20_000, tax_total: 3_600, grand_total: 23_600})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")
      assert [%{"txval" => 800.0, "camt" => 72.0, "samt" => 72.0}] = json["b2cs"]
      assert json["cdnur"] == []

      note(credited, %{
        note_type: "Debit",
        subtotal: 40_000,
        tax_total: 7_200,
        grand_total: 47_200
      })

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")
      assert [%{"txval" => 1_200.0, "camt" => 108.0, "samt" => 108.0}] = json["b2cs"]
    end

    test "leaves a consumer sale refunded in full out of Tables 7 and 12" do
      refunded = small_consumer_invoice()
      item(refunded, %{rate: 100_000})
      note(refunded, %{subtotal: 100_000, tax_total: 18_000, grand_total: 118_000})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert json["b2cs"] == []
      assert json["hsn"]["hsn_b2c"] == []
    end

    test "marks a reverse-charge invoice" do
      invoice(%{invoice_number: "RCM-1", reverse_charge: true})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"inv" => [%{"rchrg" => "Y"}]}] = json["b2b"]
    end

    test "reports the number ranges used in Table 13, cancelled and binned included" do
      binned_at = DateTime.truncate(DateTime.utc_now(), :second)

      for number <- 1..5 do
        attrs =
          case number do
            3 -> %{status: "Cancelled"}
            4 -> %{deleted_at: binned_at}
            _issued -> %{}
          end

        invoice(Map.put(attrs, :invoice_number, "INV-000#{number}"))
      end

      noted = invoice(%{invoice_number: "INV-0006"})
      note(noted, %{note_number: "CN-0001"})
      note(noted, %{note_number: "CN-0002", status: "Cancelled"})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert %{"doc_det" => [invoices, credit]} = json["doc_issue"]

      assert %{"doc_num" => 1, "docs" => [range]} = invoices

      assert range == %{
               "num" => 1,
               "from" => "INV-0001",
               "to" => "INV-0006",
               "totnum" => 6,
               "cancel" => 2,
               "net_issue" => 4
             }

      assert %{"doc_num" => 5, "docs" => [%{"totnum" => 2, "cancel" => 1}]} = credit
    end

    test "starts a second Table 13 row when the series prefix changes" do
      invoice(%{invoice_number: "A-9"})
      invoice(%{invoice_number: "A-10"})
      invoice(%{invoice_number: "B-1"})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert %{"doc_det" => [%{"docs" => [first, second]}]} = json["doc_issue"]
      # By number, not by text: A-10 comes after A-9.
      assert %{"from" => "A-9", "to" => "A-10", "totnum" => 2} = first
      assert %{"from" => "B-1", "to" => "B-1", "totnum" => 1} = second
    end
  end

  # ₹1.77 lakh, inter-state, to a buyer with no GSTIN.
  defp big_consumer_invoice(attrs) do
    invoice(
      Map.merge(
        %{
          client_gstin: nil,
          place_of_supply: "Karnataka (29)",
          taxable_value: 15_000_000,
          cgst_amount: 0,
          sgst_amount: 0,
          igst_amount: 2_700_000,
          grand_total: 17_700_000
        },
        attrs
      )
    )
  end

  defp small_consumer_invoice do
    invoice(%{
      client_gstin: nil,
      taxable_value: 100_000,
      cgst_amount: 9_000,
      sgst_amount: 9_000,
      grand_total: 118_000
    })
  end

  defp note(invoice, attrs) do
    client = Repo.insert!(%Client{name: "Delta Retailers", email: "delta@example.com"})

    defaults = %{
      client_id: client.id,
      note_number: "N-#{System.unique_integer([:positive])}",
      note_date: ~D[2026-03-15],
      note_type: "Credit",
      reason: "Rate revised",
      invoice_id: invoice.id
    }

    Repo.insert!(struct(%CreditNote{}, Map.merge(defaults, attrs)))
  end

  # Summed in paise, so float rupees compare exactly.
  defp total(rows, key), do: rows |> Enum.map(&round((&1[key] || 0) * 100)) |> Enum.sum()
end
