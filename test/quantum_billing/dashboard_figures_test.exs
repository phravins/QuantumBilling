defmodule QuantumBilling.DashboardFiguresTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice

  defp insert_invoice(attrs) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_date: Date.utc_today(),
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

  describe "month_totals/1" do
    test "adds up the tax charged on this month's invoices" do
      today = Date.utc_today()

      insert_invoice(%{invoice_number: "INV-A", invoice_date: today})

      insert_invoice(%{
        invoice_number: "INV-B",
        invoice_date: today,
        cgst_amount: 0,
        sgst_amount: 0,
        igst_amount: 3_600,
        taxable_value: 20_000,
        grand_total: 23_600
      })

      totals = Invoices.month_totals(today)

      assert totals.count == 2
      assert totals.taxable_value == 30_000
      # The card used to read ₹0 no matter how much had been billed.
      assert totals.tax == 900 + 900 + 3_600
      assert totals.invoice_value == 35_400
    end

    test "leaves out other months and cancelled invoices" do
      today = Date.utc_today()
      last_month = today |> Date.beginning_of_month() |> Date.add(-1)

      insert_invoice(%{invoice_number: "INV-OLD", invoice_date: last_month})
      insert_invoice(%{invoice_number: "INV-VOID", invoice_date: today, status: "Cancelled"})

      assert Invoices.month_totals(today).count == 0
    end

    test "reads zero on an empty table rather than nil" do
      assert %{count: 0, tax: 0, taxable_value: 0} = Invoices.month_totals()
    end
  end

  describe "monthly_tax_split/2" do
    test "splits each month into CGST+SGST and IGST" do
      today = ~D[2026-09-15]

      insert_invoice(%{invoice_number: "INV-SEP", invoice_date: ~D[2026-09-02]})

      insert_invoice(%{
        invoice_number: "INV-AUG",
        invoice_date: ~D[2026-08-20],
        cgst_amount: 0,
        sgst_amount: 0,
        igst_amount: 5_400
      })

      months = Invoices.monthly_tax_split(6, today)

      assert length(months) == 6
      assert Enum.map(months, & &1.label) == ~w(Apr May Jun Jul Aug Sep)

      august = Enum.find(months, &(&1.label == "Aug"))
      september = Enum.find(months, &(&1.label == "Sep"))

      assert august.igst == 5_400
      assert august.cgst_sgst == 0
      assert september.cgst_sgst == 1_800
      assert september.igst == 0
    end

    test "includes months with nothing billed, as zeros" do
      months = Invoices.monthly_tax_split(6, ~D[2026-09-15])

      assert length(months) == 6
      assert Enum.all?(months, &(&1.cgst_sgst == 0 and &1.igst == 0))
    end

    test "spans a year boundary correctly" do
      months = Invoices.monthly_tax_split(6, ~D[2026-02-10])

      assert Enum.map(months, & &1.label) == ~w(Sep Oct Nov Dec Jan Feb)
    end
  end
end
