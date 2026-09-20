defmodule QuantumBilling.GSTNExporterTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Compliance.GSTNExporter
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
      taxable_value: 50_000,
      cgst_amount: 4_500,
      sgst_amount: 4_500,
      grand_total: 59_000
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
      rate: 10_000,
      tax_rate: 18,
      amount: 10_000,
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

      # The export used to put every invoice ever issued into every month's
      # return, which is a false filing rather than an inconvenience.
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
          taxable_value: 20_000,
          cgst_amount: 1_150,
          sgst_amount: 1_150,
          grand_total: 22_300
        })

      item(invoice, %{description: "Goods", hsn_sac: "1001", tax_rate: 5, position: 0})
      item(invoice, %{description: "Service", hsn_sac: "998313", tax_rate: 18, position: 1})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      [%{"inv" => [entry]}] = json["b2b"]

      rates = entry["itms"] |> Enum.map(& &1["itm_det"]["rt"]) |> Enum.sort()

      # Every line used to be reported at 18% whatever was charged.
      assert rates == [5.0, 18.0]

      assert Enum.sum(Enum.map(entry["itms"], & &1["itm_det"]["txval"])) == 20_000
      assert Enum.sum(Enum.map(entry["itms"], & &1["itm_det"]["camt"])) == 1_150
    end

    test "summarises HSN by code without raising on the field name" do
      invoice = invoice(%{invoice_number: "HSN-ONE"})
      item(invoice, %{hsn_sac: "998313", tax_rate: 18})

      # `item.hsn_code` does not exist on the schema. Reading it raised
      # KeyError, so this export had never once produced a file.
      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"hsn_sc" => "998313"} = row] = json["hsn"]["data"]
      assert row["txval"] == 10_000
    end

    test "puts a large inter-state consumer sale in b2cl, not b2cs" do
      invoice(%{
        invoice_number: "BIG-B2C",
        client_gstin: nil,
        place_of_supply: "Karnataka (29)",
        company_state: "Maharashtra (27)",
        taxable_value: 300_000,
        cgst_amount: 0,
        sgst_amount: 0,
        igst_amount: 54_000,
        grand_total: 354_000
      })

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"pos" => "29", "inv" => [%{"inum" => "BIG-B2C"}]}] = json["b2cl"]
      assert json["b2b"] == []
    end

    test "summarises small consumer sales in b2cs" do
      invoice(%{
        invoice_number: "SMALL-B2C",
        client_gstin: nil,
        taxable_value: 1_000,
        cgst_amount: 90,
        sgst_amount: 90,
        grand_total: 1_180
      })

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("032026")

      assert [%{"typ" => "OE", "pos" => "27", "txval" => 1_000}] = json["b2cs"]
      assert json["b2cl"] == []
    end

    test "is empty, not broken, for a month with nothing in it" do
      invoice(%{invoice_date: ~D[2026-03-01]})

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("072026")

      assert json["b2b"] == []
      assert json["b2cl"] == []
      assert json["b2cs"] == []
      assert json["cdnr"] == []
      assert json["hsn"]["data"] == []
    end
  end

  describe "period_summary/1" do
    test "counts what the period would file, before the file is opened" do
      invoice(%{invoice_date: ~D[2026-03-02]})
      invoice(%{invoice_date: ~D[2026-03-20], status: "Cancelled"})
      invoice(%{invoice_date: ~D[2026-04-02]})

      assert {:ok, summary} = GSTNExporter.period_summary("032026")

      # The cancelled one is not a supply, and April is not this period.
      assert summary.count == 1
      assert summary.value == 59_000
      assert summary.tax == 9_000
    end

    test "refuses a period it cannot parse" do
      assert {:error, _} = GSTNExporter.period_summary("whenever")
    end
  end
end
