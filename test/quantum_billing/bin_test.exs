defmodule QuantumBilling.BinTest do
  @moduledoc """
  What moving an invoice to the Bin does, asked of every part of the
  application that reads invoices.

  One file rather than a test in each context's own: the risk being guarded
  against is a single read that was missed, so the reads are listed together
  where a new one is conspicuous by its absence.
  """
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Audit
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Compliance.GSTNExporter
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Payments
  alias QuantumBilling.Reports

  # Dated today so the "this month" figures see it, registered so GSTR-1 files
  # it as B2B, and over the e-way bill threshold.
  defp invoice_fixture(attrs \\ %{}) do
    defaults = %{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: Date.utc_today(),
      place_of_supply: "Maharashtra (27)",
      company_state: "Maharashtra (27)",
      client_name: "Delta Retailers",
      client_gstin: "27CCCDE1234F1Z5",
      taxable_value: 100_000,
      cgst_amount: 9_000,
      sgst_amount: 9_000,
      igst_amount: 0,
      cess_amount: 0,
      grand_total: 118_000,
      status: "E-Invoice Generated",
      public_token: "tok-#{System.unique_integer([:positive])}"
    }

    invoice = Repo.insert!(struct(%Invoice{}, Map.merge(defaults, attrs)))

    Repo.insert!(%InvoiceItem{
      invoice_id: invoice.id,
      description: "Consulting",
      hsn_sac: "998313",
      quantity: 1,
      unit: "Nos",
      rate: 100_000,
      tax_rate: 18,
      amount: 100_000,
      position: 0
    })

    invoice
  end

  # A credit note is raised against a client, so an invoice that is going to
  # carry one needs to belong to one.
  defp invoice_with_client_fixture do
    client = Repo.insert!(%Client{name: "Delta Retailers", email: "accounts@delta.test"})
    invoice_fixture(%{client_id: client.id})
  end

  defp credit_note_fixture(invoice) do
    {:ok, note} =
      CreditNotes.create_credit_note_for_invoice(invoice, %{
        "note_type" => "Credit",
        "reason" => "Returned",
        "grand_total" => Decimal.new("18000.00")
      })

    note
  end

  defp binned(invoice) do
    {:ok, binned} = Invoices.delete_invoice(invoice)
    binned
  end

  defp period(%Date{} = date), do: Calendar.strftime(date, "%m%Y")

  describe "delete_invoice/2" do
    test "keeps the row and everything that hangs off it" do
      invoice = invoice_fixture()

      assert {:ok, %Invoice{deleted_at: %DateTime{}}} = Invoices.delete_invoice(invoice)

      assert Repo.get(Invoice, invoice.id)
      assert Repo.aggregate(where(InvoiceItem, invoice_id: ^invoice.id), :count, :id) == 1
    end

    test "takes the invoice out of the lists and the lookups" do
      kept = invoice_fixture()
      gone = binned(invoice_fixture())

      assert Enum.map(Invoices.list_invoices(), & &1.id) == [kept.id]
      assert %{total: 1, rows: [%{id: id}]} = Invoices.page()
      assert id == kept.id
      assert Enum.map(Invoices.recent_invoices(), & &1.id) == [kept.id]

      assert Invoices.get_invoice(gone.id) == nil
      assert Invoices.get_invoice_by_number(gone.invoice_number) == nil
      assert Invoices.get_invoice_by_token(gone.public_token) == nil
      assert_raise Ecto.NoResultsError, fn -> Invoices.get_invoice!(gone.id) end

      # The one next to it is untouched.
      assert Invoices.get_invoice(kept.id)
      assert Invoices.get_invoice_by_token(kept.public_token)
    end

    test "takes the invoice out of the dashboard figures" do
      invoice_fixture()
      binned(invoice_fixture())

      assert %{count: 1, revenue: 118_000, tax: 18_000, outstanding: 118_000} = Invoices.totals()
      assert %{count: 1, invoice_value: 118_000} = Invoices.month_totals()
      assert Invoices.status_counts() == %{"E-Invoice Generated" => 1}

      assert Invoices.monthly_tax_split()
             |> Enum.map(&(&1.cgst_sgst + &1.igst))
             |> Enum.sum() == 18_000
    end

    test "takes the invoice out of the e-way bill prompts" do
      kept = invoice_fixture()
      binned(invoice_fixture())

      assert Enum.map(Invoices.awaiting_e_way_bill(), & &1.id) == [kept.id]
      assert Invoices.count_requiring_e_way_bill() == 1
    end

    test "a note against a binned invoice no longer adjusts what is owed" do
      kept = invoice_fixture()
      gone = invoice_with_client_fixture()
      credit_note_fixture(gone)

      assert Invoices.totals().outstanding == 118_000 * 2 - 18_000

      binned(gone)

      # Neither the invoice nor the credit against it: only what the kept
      # invoice is owed.
      assert Invoices.totals().outstanding == kept.grand_total
      assert CreditNotes.list_credit_notes() == []
    end

    test "is written to the audit trail against the user who did it" do
      user = QuantumBilling.AccountsFixtures.user_fixture()
      invoice = invoice_fixture()

      {:ok, _binned} = Invoices.delete_invoice(invoice, user_id: user.id)

      assert [log] = Audit.list_audit_logs()
      assert log.action == "bin_invoice"
      assert log.resource_type == "Invoice"
      assert log.resource_id == to_string(invoice.id)
      assert log.user_id == user.id
      assert log.details["invoice_number"] == invoice.invoice_number
    end

    test "tells the pages that are open" do
      Invoices.subscribe()
      invoice = invoice_fixture()

      {:ok, _binned} = Invoices.delete_invoice(invoice)

      assert_receive {:invoice_changed, %Invoice{deleted_at: %DateTime{}}}
    end
  end

  describe "the reports and returns" do
    test "a binned invoice is out of the Reports page" do
      kept = invoice_fixture()
      binned(invoice_fixture(%{client_name: "Withdrawn Traders"}))

      filters = Map.put(Reports.default_filters(), :date_range, "All Time")

      assert Enum.map(Reports.invoices(), & &1.id) == [kept.id]
      assert Enum.map(Reports.invoices(filters), & &1.id) == [kept.id]
      assert %{count: 1, taxable_value: 100_000} = Reports.totals(filters)
      assert Reports.aggregate(filters).total_count == 1
      refute "Withdrawn Traders" in Reports.client_names()
    end

    test "a binned invoice is out of the GSTR-1 export and its summary" do
      invoice_fixture(%{invoice_number: "KEPT-1"})
      binned(invoice_fixture(%{invoice_number: "BINNED-1"}))

      period = period(Date.utc_today())

      assert {:ok, json} = GSTNExporter.generate_gstr1_json(period)
      assert for(party <- json["b2b"], inv <- party["inv"], do: inv["inum"]) == ["KEPT-1"]

      assert {:ok, %{count: 1, value: 118_000}} = GSTNExporter.period_summary(period)
    end

    test "a note against a binned invoice is out of the GSTR-1 export" do
      gone = invoice_with_client_fixture()
      credit_note_fixture(gone)

      period = period(Date.utc_today())

      assert {:ok, %{"cdnr" => [_party]}} = GSTNExporter.generate_gstr1_json(period)

      binned(gone)

      assert {:ok, %{"cdnr" => []}} = GSTNExporter.generate_gstr1_json(period)
    end

    test "a binned invoice's e-way bill is out of the e-way bill list" do
      kept = invoice_fixture(%{client_state: "Karnataka"})
      gone = invoice_fixture(%{client_state: "Karnataka"})

      params = %{"distance_km" => "180", "vehicle_number" => "MH04CD5678"}
      {:ok, kept_bill} = EWayBills.generate_e_way_bill(kept, params)
      {:ok, gone_bill} = EWayBills.generate_e_way_bill(gone, params)

      binned(gone)

      assert %{total: 1, rows: [row]} = EWayBills.page()
      assert row.id == kept_bill.id
      assert length(EWayBills.export_rows()) == 1

      # Out of the list, not out of the database: it comes back with the invoice.
      assert EWayBills.get_e_way_bill(gone_bill.id)
    end
  end

  describe "a payment for a binned invoice" do
    test "is still recorded against it" do
      gone = binned(invoice_fixture(%{invoice_number: "INV-7701", status: "Draft"}))

      payload = %{
        "event" => "payment_link.paid",
        "payload" => %{
          "payment_link" => %{"entity" => %{"id" => "plink_1", "reference_id" => "INV-7701"}},
          "payment" => %{"entity" => %{"id" => "pay_1"}}
        }
      }

      assert {:ok, paid} = Payments.process_razorpay_webhook(payload)
      assert paid.id == gone.id
      assert paid.status == "Paid"

      # Recording the payment does not pull the invoice back out of the Bin.
      assert Invoices.get_invoice(gone.id) == nil
      assert %Invoice{status: "Paid"} = Invoices.get_deleted_invoice(gone.id)
    end
  end

  describe "restore_invoice/2" do
    test "puts the invoice back everywhere, as it was" do
      invoice = invoice_fixture()
      gone = binned(invoice)

      assert [%Invoice{id: id}] = Invoices.list_deleted_invoices()
      assert id == invoice.id
      assert Invoices.count_deleted_invoices() == 1

      assert {:ok, %Invoice{deleted_at: nil}} = Invoices.restore_invoice(gone)

      assert Invoices.list_deleted_invoices() == []
      assert Invoices.get_deleted_invoice(invoice.id) == nil

      restored = Invoices.get_invoice(invoice.id)
      assert restored.invoice_number == invoice.invoice_number
      assert restored.grand_total == invoice.grand_total
      assert [%InvoiceItem{description: "Consulting"}] = restored.items
      assert Invoices.totals().count == 1
    end
  end

  describe "purge_invoice/2" do
    test "removes the invoice and its line items for good" do
      gone = binned(invoice_fixture())

      assert {:ok, _purged} = Invoices.purge_invoice(gone)

      refute Repo.get(Invoice, gone.id)
      assert Repo.aggregate(where(InvoiceItem, invoice_id: ^gone.id), :count, :id) == 0
      assert Invoices.list_deleted_invoices() == []
    end

    # The delete that cannot be undone is only reachable through the Bin, so an
    # invoice that is still live cannot be destroyed by calling it directly.
    test "refuses an invoice that is not in the Bin" do
      invoice = invoice_fixture()

      assert {:error, :not_in_bin} = Invoices.purge_invoice(invoice)
      assert Repo.get(Invoice, invoice.id)
    end
  end

  describe "get_deleted_invoice/1" do
    test "finds only what is in the Bin" do
      kept = invoice_fixture()
      gone = binned(invoice_fixture())

      assert %Invoice{items: [_item]} = Invoices.get_deleted_invoice(gone.id)
      assert Invoices.get_deleted_invoice(kept.id) == nil
      assert Invoices.get_deleted_invoice("not-an-id") == nil
    end
  end
end
