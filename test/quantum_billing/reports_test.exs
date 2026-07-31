defmodule QuantumBilling.ReportsTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Reports

  # The aggregations all take a list, so they stay fully testable with no sample
  # data in the application. These fixtures live here, in the test, which is the
  # only place invented records belong.
  defp invoice(attrs) do
    Map.merge(
      %{
        date: Date.utc_today(),
        client: "Acme Traders",
        gstin: "27AAACP8542D1ZS",
        status: "E-Invoice Generated",
        tax_type: "CGST + SGST",
        taxable_value: 10_000,
        cgst: 900,
        sgst: 900,
        igst: 0,
        cess: 0
      },
      Map.new(attrs)
    )
  end

  defp intra(attrs \\ []), do: invoice(attrs)

  defp inter(attrs \\ []) do
    invoice([tax_type: "IGST", cgst: 0, sgst: 0, igst: 1_800] ++ attrs)
  end

  defp cess(attrs \\ []) do
    invoice([tax_type: "CESS", cgst: 0, sgst: 0, igst: 0, cess: 1_200] ++ attrs)
  end

  defp all_time(invoices, extra \\ %{}) do
    Reports.filter(invoices, Map.merge(%{date_range: "All Time"}, extra))
  end

  describe "invoices/0" do
    test "returns nothing until the schema lands" do
      assert Reports.invoices() == []
    end
  end

  describe "filter/2" do
    test "an unset filter matches everything" do
      invoices = [intra(), inter(), cess()]

      assert length(all_time(invoices)) == 3
    end

    test "narrows by status" do
      invoices = [intra(), intra(status: "Cancelled"), inter(status: "Cancelled")]

      rows = all_time(invoices, %{status: "Cancelled"})

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.status == "Cancelled"))
    end

    test "narrows by client" do
      invoices = [intra(), inter(client: "Beta Corp")]

      assert [%{client: "Beta Corp"}] = all_time(invoices, %{client: "Beta Corp"})
    end

    test "narrows by date range" do
      today = Date.utc_today()
      last_month = today |> Date.beginning_of_month() |> Date.add(-1)

      invoices = [intra(date: today), intra(date: last_month)]

      rows = Reports.filter(invoices, %{date_range: "This Month"})

      assert [%{date: ^today}] = rows
    end

    test "matches a partial GSTIN, case-insensitively" do
      invoices = [intra(), inter(gstin: "29AABCU9603R1ZM")]

      assert [%{gstin: "29AABCU9603R1ZM"}] = all_time(invoices, %{gstin: "29aabcu"})
    end

    test "combines filters" do
      invoices = [
        intra(client: "Acme Traders", status: "Cancelled"),
        intra(client: "Beta Corp", status: "Cancelled"),
        intra(client: "Acme Traders", status: "E-Invoice Generated")
      ]

      rows = all_time(invoices, %{client: "Acme Traders", status: "Cancelled"})

      assert length(rows) == 1
    end

    test "an impossible combination yields nothing" do
      assert all_time([intra()], %{gstin: "NOPE"}) == []
    end

    test "an empty set stays empty" do
      assert all_time([]) == []
    end
  end

  describe "summary/1" do
    test "totals equal the sum of the rows" do
      invoices = [intra(taxable_value: 10_000), inter(taxable_value: 20_000)]

      summary = Reports.summary(invoices)

      assert summary.count == 2
      assert summary.taxable_value == 30_000
      # 900 + 900 intra, 1_800 inter
      assert summary.tax_amount == 3_600
      assert summary.invoice_value == 33_600
    end

    test "invoice value is always taxable plus tax" do
      summary = Reports.summary([intra(), inter(), cess()])

      assert summary.invoice_value == summary.taxable_value + summary.tax_amount
    end

    test "reports a month-over-month delta" do
      today = Date.utc_today()
      previous = today |> Date.beginning_of_month() |> Date.add(-1)

      invoices = [
        intra(date: previous, taxable_value: 10_000),
        intra(date: today, taxable_value: 20_000)
      ]

      assert Reports.summary(invoices).taxable_delta == 100.0
    end

    test "has no delta with only one month to go on" do
      assert Reports.summary([intra()]).count_delta == nil
    end

    test "handles an empty set without dividing by zero" do
      summary = Reports.summary([])

      assert summary.count == 0
      assert summary.invoice_value == 0
      assert summary.count_delta == nil
    end
  end

  describe "tax_summary/1" do
    test "the totals row reconciles with the rows above it" do
      rows = Reports.tax_summary([intra(), inter(), cess()])

      total = Enum.find(rows, & &1.total?)
      body = Enum.reject(rows, & &1.total?)

      assert length(body) == 3
      assert total.taxable_value == Enum.reduce(body, 0, &(&1.taxable_value + &2))
      assert total.total_tax == Enum.reduce(body, 0, &(&1.total_tax + &2))
    end

    test "agrees with summary/1" do
      invoices = [intra(), inter(), cess()]

      total = invoices |> Reports.tax_summary() |> Enum.find(& &1.total?)

      assert total.total_tax == Reports.summary(invoices).tax_amount
    end

    test "columns that do not apply are nil, not zero" do
      rows = Reports.tax_summary([intra(), inter()])

      igst_row = Enum.find(rows, &(&1.label == "IGST"))
      intra_row = Enum.find(rows, &(&1.label == "CGST + SGST"))

      assert igst_row.cgst == nil
      assert igst_row.sgst == nil
      assert is_integer(igst_row.igst)

      assert intra_row.igst == nil
      assert is_integer(intra_row.cgst)
    end

    test "omits a tax type with no rows" do
      labels = [intra()] |> Reports.tax_summary() |> Enum.map(& &1.label)

      assert labels == ["CGST + SGST", "Total"]
    end

    test "an empty set yields only a zeroed totals row" do
      assert [%{label: "Total", total?: true, total_tax: 0, taxable_value: 0}] =
               Reports.tax_summary([])
    end
  end

  describe "status_breakdown/1" do
    test "counts every status and sums to the total" do
      invoices = [
        intra(status: "E-Invoice Generated"),
        intra(status: "E-Invoice Generated"),
        intra(status: "Cancelled")
      ]

      breakdown = Reports.status_breakdown(invoices)

      assert Enum.reduce(breakdown, 0, &(&1.value + &2)) == 3
      assert Enum.find(breakdown, &(&1.label == "E-Invoice Generated")).value == 2
    end

    test "drops statuses with no rows" do
      assert [%{label: "Cancelled", value: 1}] =
               Reports.status_breakdown([intra(status: "Cancelled")])
    end

    test "is empty for an empty set" do
      assert Reports.status_breakdown([]) == []
    end
  end

  describe "monthly_trend/1" do
    test "is ordered oldest month first" do
      invoices = [
        intra(date: ~D[2024-03-10], taxable_value: 30_000),
        intra(date: ~D[2024-01-10], taxable_value: 10_000),
        intra(date: ~D[2024-02-10], taxable_value: 20_000)
      ]

      assert ["Jan", "Feb", "Mar"] = Enum.map(Reports.monthly_trend(invoices), & &1.label)
    end

    test "sums invoice value within a month" do
      invoices = [
        intra(date: ~D[2024-01-05], taxable_value: 10_000),
        intra(date: ~D[2024-01-25], taxable_value: 10_000)
      ]

      assert [%{label: "Jan", value: value}] = Reports.monthly_trend(invoices)
      assert value == 23_600
    end

    test "is empty for an empty set" do
      assert Reports.monthly_trend([]) == []
    end
  end

  describe "top_clients/2" do
    test "returns the highest earners, descending" do
      invoices = [
        intra(client: "Small", taxable_value: 1_000),
        intra(client: "Large", taxable_value: 100_000),
        intra(client: "Medium", taxable_value: 50_000)
      ]

      assert ["Large", "Medium", "Small"] = Enum.map(Reports.top_clients(invoices), & &1.client)
    end

    test "sums a client's invoices together" do
      invoices = [
        intra(client: "Acme Traders", taxable_value: 10_000),
        intra(client: "Acme Traders", taxable_value: 10_000)
      ]

      assert [%{client: "Acme Traders", value: 23_600}] = Reports.top_clients(invoices)
    end

    test "respects the limit" do
      invoices = Enum.map(1..8, &intra(client: "Client #{&1}", taxable_value: &1 * 1_000))

      assert length(Reports.top_clients(invoices)) == 5
      assert length(Reports.top_clients(invoices, 3)) == 3
    end

    test "is empty for an empty set" do
      assert Reports.top_clients([]) == []
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

  describe "option lists" do
    test "clients are just the sentinel until the database lands" do
      assert Reports.client_names() == ["All Clients"]
    end

    test "statuses and report types are reference data, not records" do
      assert "All Status" in Reports.statuses()
      assert "E-Invoice Generated" in Reports.statuses()
      assert "All Reports" in Reports.report_types()
    end
  end
end
