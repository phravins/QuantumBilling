defmodule QuantumBilling.ReportsTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Reports

  setup do
    invoices = Reports.invoices()
    %{invoices: invoices, all: Reports.filter(invoices, %{date_range: "All Time"})}
  end

  describe "invoices/0" do
    test "is deterministic", %{invoices: invoices} do
      assert invoices == Reports.invoices()
    end

    test "returns the full sample set", %{invoices: invoices} do
      assert length(invoices) == 256
    end

    test "tax_type always agrees with the amounts", %{invoices: invoices} do
      for row <- invoices do
        expected =
          cond do
            row.cess > 0 -> "CESS"
            row.igst > 0 -> "IGST"
            true -> "CGST + SGST"
          end

        assert row.tax_type == expected
      end
    end

    test "an intra-state supply splits the rate evenly and charges no IGST", %{invoices: invoices} do
      intra = Enum.filter(invoices, &(&1.tax_type == "CGST + SGST"))

      refute intra == []

      for row <- intra do
        assert row.cgst == row.sgst
        assert row.igst == 0
      end
    end
  end

  describe "filter/2" do
    test "an unset filter matches everything", %{invoices: invoices, all: all} do
      assert length(all) == length(invoices)
    end

    test "narrows by status", %{invoices: invoices} do
      rows = Reports.filter(invoices, %{date_range: "All Time", status: "Cancelled"})

      assert length(rows) == 17
      assert Enum.all?(rows, &(&1.status == "Cancelled"))
    end

    test "narrows by client", %{invoices: invoices} do
      rows = Reports.filter(invoices, %{date_range: "All Time", client: "Insta Capital"})

      refute rows == []
      assert Enum.all?(rows, &(&1.client == "Insta Capital"))
    end

    test "narrows by date range", %{invoices: invoices} do
      rows = Reports.filter(invoices, %{date_range: "This Month"})
      {from, to} = Reports.range_bounds("This Month")

      refute rows == []

      for row <- rows do
        assert Date.compare(row.date, from) != :lt
        assert Date.compare(row.date, to) != :gt
      end
    end

    test "matches a partial GSTIN, case-insensitively", %{invoices: invoices} do
      rows = Reports.filter(invoices, %{date_range: "All Time", gstin: "27aaacpj"})

      refute rows == []
      assert Enum.all?(rows, &String.starts_with?(&1.gstin, "27AAACPJ"))
    end

    test "combines filters", %{invoices: invoices} do
      rows =
        Reports.filter(invoices, %{
          date_range: "All Time",
          status: "E-Invoice Generated",
          client: "Insta Capital"
        })

      assert Enum.all?(rows, &(&1.status == "E-Invoice Generated" and &1.client == "Insta Capital"))
    end

    test "an impossible combination yields nothing", %{invoices: invoices} do
      assert Reports.filter(invoices, %{date_range: "All Time", gstin: "NOPE"}) == []
    end
  end

  describe "summary/1" do
    test "totals equal the sum of the rows", %{all: all} do
      summary = Reports.summary(all)

      assert summary.count == length(all)
      assert summary.taxable_value == Enum.reduce(all, 0, &(&1.taxable_value + &2))

      expected_tax =
        Enum.reduce(all, 0, fn row, acc -> acc + row.cgst + row.sgst + row.igst + row.cess end)

      assert summary.tax_amount == expected_tax
      assert summary.invoice_value == summary.taxable_value + summary.tax_amount
    end

    test "the sample data grows month over month", %{all: all} do
      summary = Reports.summary(all)

      assert summary.count_delta > 0
      assert summary.taxable_delta > 0
    end

    test "handles an empty set without dividing by zero" do
      summary = Reports.summary([])

      assert summary.count == 0
      assert summary.invoice_value == 0
      assert summary.count_delta == nil
    end
  end

  describe "tax_summary/1" do
    test "the totals row reconciles with the rows above it", %{all: all} do
      rows = Reports.tax_summary(all)
      total = Enum.find(rows, & &1.total?)
      body = Enum.reject(rows, & &1.total?)

      refute body == []
      assert total.taxable_value == Enum.reduce(body, 0, &(&1.taxable_value + &2))
      assert total.total_tax == Enum.reduce(body, 0, &(&1.total_tax + &2))
    end

    test "agrees with summary/1", %{all: all} do
      total = all |> Reports.tax_summary() |> Enum.find(& &1.total?)

      assert total.total_tax == Reports.summary(all).tax_amount
    end

    test "columns that do not apply are nil, not zero", %{all: all} do
      rows = Reports.tax_summary(all)
      igst_row = Enum.find(rows, &(&1.label == "IGST"))

      assert igst_row.cgst == nil
      assert igst_row.sgst == nil
      assert is_integer(igst_row.igst)
    end

    test "is empty for an empty set" do
      assert Reports.tax_summary([]) == [%{
               label: "Total",
               taxable_value: 0,
               cgst: nil,
               sgst: nil,
               igst: nil,
               total_tax: 0,
               total?: true
             }]
    end
  end

  describe "status_breakdown/1" do
    test "counts every status and sums to the total", %{all: all} do
      breakdown = Reports.status_breakdown(all)

      assert Enum.reduce(breakdown, 0, &(&1.value + &2)) == length(all)
      assert Enum.find(breakdown, &(&1.label == "E-Invoice Generated")).value == 198
    end

    test "drops statuses with no rows", %{invoices: invoices} do
      rows = Reports.filter(invoices, %{date_range: "All Time", status: "Cancelled"})

      assert [%{label: "Cancelled", value: 17}] = Reports.status_breakdown(rows)
    end
  end

  describe "monthly_trend/1" do
    test "is ordered oldest first and rises", %{all: all} do
      trend = Reports.monthly_trend(all)
      values = Enum.map(trend, & &1.value)

      assert Enum.map(trend, & &1.label) == ["Jan", "Feb", "Mar", "Apr", "May"]
      assert values == Enum.sort(values)
    end
  end

  describe "top_clients/1" do
    test "returns the highest earners, descending", %{all: all} do
      clients = Reports.top_clients(all)
      values = Enum.map(clients, & &1.value)

      assert length(clients) == 5
      assert values == Enum.sort(values, :desc)
    end

    test "respects the limit", %{all: all} do
      assert length(Reports.top_clients(all, 3)) == 3
    end
  end

  describe "range_bounds/1 and range_label/1" do
    test "All Time is unbounded" do
      assert Reports.range_bounds("All Time") == {nil, nil}
      assert Reports.range_label("All Time") == "All time"
    end

    test "labels a bounded range the way the header shows it" do
      assert Reports.range_label("This Month") == "01 May 2024 - 31 May 2024"
    end

    test "an unknown range falls back rather than crashing" do
      assert Reports.range_bounds("nonsense") == Reports.range_bounds("This Year")
    end
  end
end
