defmodule QuantumBilling.ReportsAggregateTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Reports

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

  @all %{
    date_range: "All Time",
    report_type: "All Reports",
    client: "All Clients",
    status: "All Status",
    gstin: ""
  }

  describe "aggregate/1" do
    test "totals match what the rows say" do
      insert_invoice(%{invoice_number: "INV-1"})

      insert_invoice(%{
        invoice_number: "INV-2",
        taxable_value: 20_000,
        cgst_amount: 1_800,
        sgst_amount: 1_800
      })

      report = Reports.aggregate(@all)

      assert report.summary.count == 2
      assert report.summary.taxable_value == 30_000
      assert report.summary.tax_amount == 5_400
      assert report.summary.invoice_value == 35_400
      assert report.total_count == 2
    end

    test "agrees with the pure list functions it replaces" do
      insert_invoice(%{invoice_number: "INV-1"})

      insert_invoice(%{
        invoice_number: "INV-2",
        place_of_supply: "Gujarat",
        cgst_amount: 0,
        sgst_amount: 0,
        igst_amount: 1_800
      })

      from_sql = Reports.aggregate(@all)
      from_rows = Reports.invoices() |> Reports.filter(@all)

      assert from_sql.summary.count == length(from_rows)
      assert from_sql.summary.taxable_value == Reports.summary(from_rows).taxable_value
      assert from_sql.summary.tax_amount == Reports.summary(from_rows).tax_amount
      assert from_sql.top_clients == Reports.top_clients(from_rows)

      assert Enum.map(from_sql.tax_rows, & &1.label) ==
               Enum.map(Reports.tax_summary(from_rows), & &1.label)
    end

    test "splits the tax summary by which taxes were actually charged" do
      insert_invoice(%{invoice_number: "INV-INTRA"})

      insert_invoice(%{
        invoice_number: "INV-INTER",
        place_of_supply: "Gujarat",
        cgst_amount: 0,
        sgst_amount: 0,
        igst_amount: 1_800
      })

      report = Reports.aggregate(@all)
      labels = Enum.map(report.tax_rows, & &1.label)

      assert "CGST + SGST" in labels
      assert "IGST" in labels
      assert List.last(report.tax_rows).total?

      intra = Enum.find(report.tax_rows, &(&1.label == "CGST + SGST"))
      # A column that does not apply to a tax type reads as a dash, not a zero.
      assert intra.igst == nil
      assert intra.cgst == 900
    end

    test "filters by date range in the database" do
      insert_invoice(%{invoice_number: "INV-OLD", invoice_date: ~D[2020-05-05]})
      insert_invoice(%{invoice_number: "INV-NEW", invoice_date: Date.utc_today()})

      assert Reports.aggregate(%{@all | date_range: "This Year"}).summary.count == 1
      assert Reports.aggregate(@all).summary.count == 2
    end

    test "filters by status, client, GSTIN and report type" do
      insert_invoice(%{
        invoice_number: "INV-1",
        status: "Cancelled",
        client_gstin: "27AAACA1234A1Z5"
      })

      insert_invoice(%{invoice_number: "INV-2", client_name: "Globex Ltd"})

      assert Reports.aggregate(%{@all | status: "Cancelled"}).summary.count == 1
      assert Reports.aggregate(%{@all | client: "Globex Ltd"}).summary.count == 1
      assert Reports.aggregate(%{@all | gstin: "27aaaca"}).summary.count == 1
      # Tax Liability reports only on invoices that reached the portal.
      assert Reports.aggregate(%{@all | report_type: "Tax Liability"}).summary.count == 1
    end

    test "ranks the top clients by what they were billed" do
      insert_invoice(%{
        invoice_number: "INV-1",
        client_name: "Small Co",
        taxable_value: 1_000,
        grand_total: 1_000
      })

      insert_invoice(%{
        invoice_number: "INV-2",
        client_name: "Big Co",
        taxable_value: 90_000,
        grand_total: 90_000
      })

      insert_invoice(%{invoice_number: "INV-3", client_name: "Big Co", taxable_value: 10_000})

      assert [%{client: "Big Co"} | _] = Reports.aggregate(@all).top_clients
    end

    test "month-over-month deltas compare the last two months present" do
      insert_invoice(%{
        invoice_number: "INV-JAN",
        invoice_date: ~D[2026-01-10],
        taxable_value: 10_000
      })

      insert_invoice(%{
        invoice_number: "INV-FEB",
        invoice_date: ~D[2026-02-10],
        taxable_value: 20_000
      })

      report = Reports.aggregate(@all)

      assert length(report.trend) == 2
      assert report.summary.taxable_delta == 100.0
      assert report.summary.count_delta == 0.0
    end

    test "reads as zero on an empty table, with the totals row still present" do
      report = Reports.aggregate(@all)

      assert report.summary.count == 0
      assert report.summary.taxable_value == 0
      assert report.summary.taxable_delta == nil
      assert report.trend == []
      assert report.breakdown == []
      assert [%{label: "Total", total?: true}] = report.tax_rows
    end
  end

  describe "stream_rows/2" do
    test "streams the filtered rows in order" do
      insert_invoice(%{invoice_number: "INV-1", invoice_date: ~D[2026-01-01]})
      insert_invoice(%{invoice_number: "INV-2", invoice_date: ~D[2026-02-01]})
      insert_invoice(%{invoice_number: "INV-3", invoice_date: ~D[2020-01-01]})

      {:ok, numbers} =
        Reports.stream_rows(
          %{@all | date_range: "This Year"},
          &Enum.map(&1, fn row -> row.number end)
        )

      assert numbers == ["INV-1", "INV-2"]
    end
  end
end
