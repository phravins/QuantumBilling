defmodule QuantumBilling.InvoicesPageTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice

  # A credit note belongs to a client as well as to an invoice, so the netting
  # tests need one behind their invoices.
  defp billed_client do
    Repo.insert!(%Client{name: "Acme Corp", email: "billing@acme.test"})
  end

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
          grand_total: 11_800,
          status: "Draft"
        },
        attrs
      )
    )
  end

  describe "page/1" do
    setup do
      for n <- 1..25 do
        insert_invoice(%{
          invoice_number: "INV-#{String.pad_leading(to_string(n), 4, "0")}",
          invoice_date: Date.add(~D[2026-01-01], n),
          client_name: if(rem(n, 2) == 0, do: "Acme Corp", else: "Globex Ltd"),
          client_gstin: if(rem(n, 2) == 0, do: "27AAACA1234A1Z5", else: "29AAACG5678B1Z2"),
          status: if(rem(n, 5) == 0, do: "Paid", else: "Draft"),
          grand_total: n * 1_000
        })
      end

      :ok
    end

    test "reads one page and counts the rest" do
      result = Invoices.page(page: 1, per_page: 10)

      assert length(result.rows) == 10
      assert result.total == 25
      assert result.total_pages == 3
      assert result.page == 1
    end

    test "clamps a page beyond the end rather than returning nothing" do
      result = Invoices.page(page: 99, per_page: 10)

      assert result.page == 3
      assert length(result.rows) == 5
    end

    test "searches the number, the client and the GSTIN" do
      assert Invoices.page(search: "INV-0007").total == 1
      assert Invoices.page(search: "globex").total == 13
      assert Invoices.page(search: "27AAACA1234A1Z5").total == 12
      assert Invoices.page(search: "nothing matches this").total == 0
    end

    test "filters by status, and 'All Status' means no filter" do
      assert Invoices.page(status: "Paid").total == 5
      assert Invoices.page(status: "All Status").total == 25
      assert Invoices.page(status: nil).total == 25
    end

    test "sorts on the allowlisted columns in both directions" do
      newest = Invoices.page(sort_field: :invoice_date, sort_dir: :desc, per_page: 1)
      oldest = Invoices.page(sort_field: :invoice_date, sort_dir: :asc, per_page: 1)

      assert hd(newest.rows).number == "INV-0025"
      assert hd(oldest.rows).number == "INV-0001"

      largest = Invoices.page(sort_field: :amount, sort_dir: :desc, per_page: 1)
      assert hd(largest.rows).amount == 25_000
    end

    test "an unknown sort field falls back rather than reaching the query" do
      result = Invoices.page(sort_field: :drop_table, sort_dir: :desc, per_page: 1)

      assert hd(result.rows).number == "INV-0025"
    end

    test "pages do not overlap or drop rows when dates collide" do
      # Every row on the same date: without a tie-breaker in the ordering, the
      # database is free to return them in a different order per page, which
      # shows one invoice twice and hides another.
      Repo.update_all(Invoice, set: [invoice_date: ~D[2026-06-01]])

      first = Invoices.page(page: 1, per_page: 10).rows
      second = Invoices.page(page: 2, per_page: 10).rows
      third = Invoices.page(page: 3, per_page: 10).rows

      numbers = Enum.map(first ++ second ++ third, & &1.number)

      assert length(numbers) == 25
      assert length(Enum.uniq(numbers)) == 25
    end

    test "per_page is clamped to something a page can render" do
      assert Invoices.page(per_page: 100_000).per_page == 200
      assert Invoices.page(per_page: 0).per_page == 1
      assert Invoices.page(per_page: "10").per_page == 1
    end
  end

  describe "totals/0 and status_counts/0" do
    test "are computed by the database, not by loading every row" do
      insert_invoice(%{invoice_number: "INV-A", grand_total: 1_000, status: "Draft"})
      insert_invoice(%{invoice_number: "INV-B", grand_total: 2_000, status: "Paid"})
      insert_invoice(%{invoice_number: "INV-C", grand_total: 4_000, status: "Cancelled"})

      totals = Invoices.totals()

      assert totals.count == 3
      assert totals.revenue == 7_000
      assert totals.paid_count == 1
      # Paid and cancelled invoices are not owed.
      assert totals.outstanding == 1_000
      assert totals.tax == 3 * 1_800

      assert %{"Draft" => 1, "Paid" => 1, "Cancelled" => 1} = Invoices.status_counts()
    end

    test "answers zero on an empty table rather than nil" do
      assert %{count: 0, revenue: 0, outstanding: 0} = Invoices.totals()
    end

    test "nets credit notes off what is still owed" do
      invoice =
        insert_invoice(%{
          client_id: billed_client().id,
          invoice_number: "INV-CN",
          grand_total: 10_000
        })

      assert Invoices.totals().outstanding == 10_000

      {:ok, _note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "note_type" => "Credit",
          "grand_total" => Decimal.new("4000")
        })

      # An invoice partly credited is partly owed. The figure used to be the
      # full invoice value however much of it had been credited back.
      assert Invoices.totals().outstanding == 6_000
    end

    test "adds debit notes to what is owed" do
      invoice =
        insert_invoice(%{
          client_id: billed_client().id,
          invoice_number: "INV-DN",
          grand_total: 10_000
        })

      {:ok, _note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "note_type" => "Debit",
          "grand_total" => Decimal.new("2500")
        })

      assert Invoices.totals().outstanding == 12_500
    end

    test "ignores notes against invoices that are no longer owed" do
      paid =
        insert_invoice(%{
          client_id: billed_client().id,
          invoice_number: "INV-PAID",
          grand_total: 10_000,
          status: "Paid"
        })

      owed = insert_invoice(%{invoice_number: "INV-OWED", grand_total: 3_000})

      {:ok, _note} =
        CreditNotes.create_credit_note_for_invoice(paid, %{
          "note_type" => "Credit",
          "grand_total" => Decimal.new("10000")
        })

      # Crediting a settled invoice is a refund, not a reduction in
      # receivables, and must not eat into what other customers still owe.
      assert Invoices.totals().outstanding == 3_000
      assert owed.grand_total == 3_000
    end

    test "never reports a negative receivable" do
      invoice =
        insert_invoice(%{
          client_id: billed_client().id,
          invoice_number: "INV-OVER",
          grand_total: 5_000
        })

      {:ok, _note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "note_type" => "Credit",
          "grand_total" => Decimal.new("9000")
        })

      assert Invoices.totals().outstanding == 0
    end

    test "ignores a cancelled note" do
      invoice =
        insert_invoice(%{
          client_id: billed_client().id,
          invoice_number: "INV-VOIDCN",
          grand_total: 10_000
        })

      {:ok, note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "note_type" => "Credit",
          "grand_total" => Decimal.new("4000")
        })

      Repo.update!(Ecto.Changeset.change(note, status: "Cancelled"))

      assert Invoices.totals().outstanding == 10_000
    end
  end

  describe "recent_invoices/1" do
    test "returns the newest few, not the first few of everything" do
      insert_invoice(%{invoice_number: "INV-OLD", invoice_date: ~D[2025-01-01]})
      insert_invoice(%{invoice_number: "INV-NEW", invoice_date: ~D[2026-12-31]})

      assert [%{number: "INV-NEW"} | _] = Invoices.recent_invoices(2)
      assert length(Invoices.recent_invoices(1)) == 1
    end
  end
end
