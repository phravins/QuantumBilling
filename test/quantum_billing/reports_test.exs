defmodule QuantumBilling.ReportsTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Reports

  @all %{
    date_range: "All Time",
    report_type: "All Reports",
    client: "All Clients",
    status: "All Status",
    gstin: ""
  }

  defp insert_invoice(attrs) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_name: "Acme Corp",
          taxable_value: 10_000,
          cgst_amount: 900,
          sgst_amount: 900,
          igst_amount: 0,
          cess_amount: 0,
          grand_total: 11_800,
          status: "E-Invoice Generated"
        },
        attrs
      )
    )
  end

  defp inter(attrs) do
    insert_invoice(
      Map.merge(
        %{place_of_supply: "Gujarat", cgst_amount: 0, sgst_amount: 0, igst_amount: 1_800},
        attrs
      )
    )
  end

  defp cess(attrs) do
    insert_invoice(
      Map.merge(%{cgst_amount: 0, sgst_amount: 0, igst_amount: 0, cess_amount: 1_200}, attrs)
    )
  end

  defp numbers(filters) do
    {:ok, numbers} = Reports.stream_rows(filters, &Enum.map(&1, fn row -> row.number end))
    numbers
  end

  describe "stream_rows/2" do
    test "maps each invoice to an export row" do
      insert_invoice(%{
        invoice_number: "INV-001",
        invoice_date: ~D[2024-05-15],
        client_gstin: "27AAACP8542D1ZS",
        place_of_supply: "Maharashtra (27)",
        company_state: "Maharashtra (27)"
      })

      assert {:ok, [row]} = Reports.stream_rows(@all, &Enum.to_list/1)
      assert row.number == "INV-001"
      assert row.date == ~D[2024-05-15]
      assert row.client == "Acme Corp"
      assert row.gstin == "27AAACP8542D1ZS"
      assert row.tax_type == "CGST + SGST"
      assert row.taxable_value == 10_000
      assert row.cgst == 900
      assert row.sgst == 900
      assert row.igst == 0
    end

    test "streams oldest first" do
      insert_invoice(%{invoice_number: "INV-FEB", invoice_date: ~D[2026-02-01]})
      insert_invoice(%{invoice_number: "INV-JAN", invoice_date: ~D[2026-01-01]})
      insert_invoice(%{invoice_number: "INV-OLD", invoice_date: ~D[2020-01-01]})

      assert numbers(@all) == ["INV-OLD", "INV-JAN", "INV-FEB"]
    end

    test "filters by date range" do
      insert_invoice(%{invoice_number: "INV-OLD", invoice_date: ~D[2020-05-05]})
      insert_invoice(%{invoice_number: "INV-NEW", invoice_date: Date.utc_today()})

      assert numbers(%{@all | date_range: "This Year"}) == ["INV-NEW"]
      assert numbers(@all) == ["INV-OLD", "INV-NEW"]
    end

    test "filters by status, client, GSTIN and report type" do
      insert_invoice(%{
        invoice_number: "INV-1",
        status: "Cancelled",
        client_gstin: "27AAACA1234A1Z5"
      })

      insert_invoice(%{invoice_number: "INV-2", client_name: "Globex Ltd"})
      cess(%{invoice_number: "INV-3"})

      assert numbers(%{@all | status: "Cancelled"}) == ["INV-1"]
      assert numbers(%{@all | client: "Globex Ltd"}) == ["INV-2"]
      assert numbers(%{@all | gstin: "27aaaca"}) == ["INV-1"]
      # Tax Liability reports only on invoices that reached the portal.
      assert numbers(%{@all | report_type: "Tax Liability"}) == ["INV-2", "INV-3"]
      assert numbers(%{@all | report_type: "ITC Summary"}) == ["INV-1", "INV-2"]
    end
  end

  describe "tax_rows/1" do
    test "splits by which taxes were charged, and the totals row reconciles" do
      insert_invoice(%{invoice_number: "INV-INTRA"})
      inter(%{invoice_number: "INV-INTER"})
      cess(%{invoice_number: "INV-CESS"})

      rows = Reports.tax_rows(@all)

      assert Enum.map(rows, & &1.label) == ["CGST + SGST", "IGST", "CESS", "Total"]

      {[total], body} = Enum.split_with(rows, & &1.total?)
      assert total.taxable_value == Enum.sum_by(body, & &1.taxable_value)
      assert total.total_tax == Enum.sum_by(body, & &1.total_tax)
      assert total.total_tax == 1_800 + 1_800 + 1_200
    end

    # A column that does not apply to a tax type reads as a dash, not a zero.
    test "columns that do not apply are nil, not zero" do
      insert_invoice(%{invoice_number: "INV-INTRA"})
      inter(%{invoice_number: "INV-INTER"})

      rows = Reports.tax_rows(@all)
      intra = Enum.find(rows, &(&1.label == "CGST + SGST"))
      igst = Enum.find(rows, &(&1.label == "IGST"))

      assert intra.cgst == 900
      assert intra.igst == nil
      assert igst.igst == 1_800
      assert igst.cgst == nil
      assert igst.sgst == nil
    end

    test "omits a tax type with no invoices" do
      insert_invoice(%{invoice_number: "INV-INTRA"})

      assert Enum.map(Reports.tax_rows(@all), & &1.label) == ["CGST + SGST", "Total"]
    end

    test "an empty table yields only a zeroed totals row" do
      assert [%{label: "Total", total?: true, total_tax: 0, taxable_value: 0}] =
               Reports.tax_rows(@all)
    end
  end

  describe "top_client_totals/2" do
    test "ranks clients by what they were billed, tax included" do
      insert_invoice(%{invoice_number: "INV-1", client_name: "Small Co", taxable_value: 1_000})
      insert_invoice(%{invoice_number: "INV-2", client_name: "Big Co", taxable_value: 90_000})
      insert_invoice(%{invoice_number: "INV-3", client_name: "Big Co", taxable_value: 10_000})

      assert [%{client: "Big Co", value: 103_600}, %{client: "Small Co", value: 2_800}] =
               Reports.top_client_totals(@all)
    end

    test "respects the limit" do
      for n <- 1..8 do
        insert_invoice(%{invoice_number: "INV-#{n}", client_name: "Client #{n}"})
      end

      assert length(Reports.top_client_totals(@all)) == 5
      assert length(Reports.top_client_totals(@all, 3)) == 3
    end

    test "is empty when nothing was billed" do
      assert Reports.top_client_totals(@all) == []
    end
  end

  describe "range_bounds/2 and range_label/2" do
    test "All Time is unbounded" do
      assert Reports.range_bounds("All Time") == {nil, nil}
      assert Reports.range_label("All Time") == "All time"
    end

    test "resolves relative to the given day" do
      assert Reports.range_bounds("This Month", ~D[2024-05-15]) ==
               {~D[2024-05-01], ~D[2024-05-31]}

      assert Reports.range_bounds("Last Month", ~D[2024-05-15]) ==
               {~D[2024-04-01], ~D[2024-04-30]}

      assert Reports.range_bounds("This Quarter", ~D[2024-05-15]) ==
               {~D[2024-04-01], ~D[2024-06-30]}

      assert Reports.range_bounds("This Year", ~D[2024-05-15]) ==
               {~D[2024-01-01], ~D[2024-12-31]}
    end

    test "defaults to today when no day is given" do
      {from, to} = Reports.range_bounds("This Month")
      today = Date.utc_today()

      assert from == Date.beginning_of_month(today)
      assert to == Date.end_of_month(today)
    end

    test "labels a bounded range the way the header shows it" do
      assert Reports.range_label("This Month", ~D[2024-05-15]) == "01 May 2024 - 31 May 2024"
    end

    test "an unknown range falls back rather than crashing" do
      assert Reports.range_bounds("nonsense", ~D[2024-05-15]) ==
               Reports.range_bounds("This Year", ~D[2024-05-15])
    end
  end
end
