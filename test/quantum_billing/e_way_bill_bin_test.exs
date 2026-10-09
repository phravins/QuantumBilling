defmodule QuantumBilling.EWayBillBinTest do
  @moduledoc """
  What moving an e-way bill to the Bin does — and the one thing it must not be
  mistaken for, which is cancelling it.
  """
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Audit
  alias QuantumBilling.EWayBills
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.PartBUpdate
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice

  defp invoice_fixture(attrs \\ %{}) do
    defaults = %{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_state: "Karnataka",
      client_name: "Acme India Pvt Ltd",
      client_gstin: "27AAAAA0000A1Z5",
      taxable_value: 100_000,
      grand_total: 118_000
    }

    Repo.insert!(struct(%Invoice{}, Map.merge(defaults, attrs)))
  end

  defp bill_fixture(invoice \\ nil) do
    {:ok, bill} =
      EWayBills.generate_e_way_bill(invoice || invoice_fixture(), %{
        "distance_km" => "180",
        "vehicle_number" => "MH04CD5678"
      })

    bill
  end

  defp binned(bill) do
    {:ok, binned} = EWayBills.delete_e_way_bill(bill)
    binned
  end

  describe "delete_e_way_bill/2" do
    test "keeps the row and its vehicle history" do
      {:ok, bill} =
        EWayBills.update_part_b(bill_fixture(), %{
          "vehicle_number" => "KA05CD9876",
          "mode_of_transport" => "Road"
        })

      assert {:ok, %EWayBill{deleted_at: %DateTime{}}} = EWayBills.delete_e_way_bill(bill)

      assert Repo.get(EWayBill, bill.id)
      assert Repo.aggregate(where(PartBUpdate, e_way_bill_id: ^bill.id), :count, :id) == 2
    end

    # Deleting is a statement about this application's list. The bill is as
    # live on the portal as it was, and the record of it has to go on saying so.
    test "does not cancel the bill" do
      gone = binned(bill_fixture())

      assert gone.status == "Active"
      assert gone.cancelled_at == nil
      assert gone.cancellation_reason == nil
    end

    test "takes the bill out of the list, the export and the lookups" do
      kept = bill_fixture()
      gone = binned(bill_fixture())

      assert Enum.map(EWayBills.list_e_way_bills(), & &1.id) == [kept.id]
      assert %{total: 1, rows: [row]} = EWayBills.page()
      assert row.id == kept.id
      assert Enum.map(EWayBills.export_rows(), & &1.id) == [kept.id]

      assert EWayBills.get_e_way_bill(gone.id) == nil
      assert_raise Ecto.NoResultsError, fn -> EWayBills.get_e_way_bill!(gone.id) end
      assert EWayBills.live_bill_for_invoice(gone.invoice_id) == nil

      # The one next to it is untouched.
      assert EWayBills.get_e_way_bill(kept.id)
      assert EWayBills.live_bill_for_invoice(kept.invoice_id)
    end

    test "leaves its invoice free to have another bill raised" do
      invoice = invoice_fixture()
      bill = bill_fixture(invoice)

      assert Invoices.awaiting_e_way_bill() == []
      assert Invoices.count_requiring_e_way_bill() == 0
      assert {:error, :already_issued} = EWayBills.generate_e_way_bill(invoice, %{})

      binned(bill)

      assert Enum.map(Invoices.awaiting_e_way_bill(), & &1.id) == [invoice.id]
      assert Invoices.count_requiring_e_way_bill() == 1

      assert {:ok, %EWayBill{} = second} =
               EWayBills.generate_e_way_bill(invoice, %{
                 "distance_km" => "90",
                 "vehicle_number" => "MH12AB1234"
               })

      assert EWayBills.live_bill_for_invoice(invoice.id).id == second.id
    end

    test "is offered for a bill in any state" do
      bill = bill_fixture()
      {:ok, cancelled} = EWayBills.cancel_e_way_bill(bill, %{"cancellation_reason" => "Wrong"})

      assert {:ok, %EWayBill{status: "Cancelled", deleted_at: %DateTime{}}} =
               EWayBills.delete_e_way_bill(cancelled)
    end

    test "is written to the audit trail against the user who did it" do
      user = QuantumBilling.AccountsFixtures.user_fixture()
      bill = bill_fixture()

      {:ok, _binned} = EWayBills.delete_e_way_bill(bill, user_id: user.id)

      assert log = Enum.find(Audit.list_audit_logs(), &(&1.action == "bin_e_way_bill"))
      assert log.resource_type == "EWayBill"
      assert log.resource_id == to_string(bill.id)
      assert log.user_id == user.id
      assert log.details["ewb_number"] == bill.ewb_number
    end

    test "tells the pages that are open" do
      bill = bill_fixture()
      EWayBills.subscribe()

      {:ok, _binned} = EWayBills.delete_e_way_bill(bill)

      assert_receive {:e_way_bill_changed, %EWayBill{deleted_at: %DateTime{}}}
    end

    test "is a no-op for a bill that is already there" do
      gone = binned(bill_fixture())

      assert {:ok, again} = EWayBills.delete_e_way_bill(gone)
      assert again.deleted_at == gone.deleted_at
    end
  end

  describe "restore_e_way_bill/2" do
    test "puts the bill back as its invoice's live bill" do
      bill = bill_fixture()
      gone = binned(bill)

      assert [%EWayBill{id: id, invoice: %Invoice{}}] = EWayBills.list_deleted_e_way_bills()
      assert id == bill.id

      assert {:ok, %EWayBill{deleted_at: nil}} = EWayBills.restore_e_way_bill(gone)

      assert EWayBills.list_deleted_e_way_bills() == []
      assert EWayBills.get_deleted_e_way_bill(bill.id) == nil
      assert EWayBills.get_e_way_bill(bill.id).ewb_number == bill.ewb_number
      assert EWayBills.live_bill_for_invoice(bill.invoice_id).id == bill.id
      assert Invoices.awaiting_e_way_bill() == []
    end

    # An invoice carries one live bill, and the one raised since is the one in
    # use.
    test "is refused when the invoice has had another bill raised since" do
      invoice = invoice_fixture()
      gone = binned(bill_fixture(invoice))
      second = bill_fixture(invoice)

      assert {:error, :invoice_has_live_bill} = EWayBills.restore_e_way_bill(gone)

      assert EWayBills.get_deleted_e_way_bill(gone.id)
      assert EWayBills.live_bill_for_invoice(invoice.id).id == second.id
    end

    # A cancelled bill never held the invoice's slot, so it has none to come
    # back into and nothing to collide with.
    test "a cancelled bill comes back beside the one that replaced it" do
      invoice = invoice_fixture()

      {:ok, cancelled} =
        EWayBills.cancel_e_way_bill(bill_fixture(invoice), %{"cancellation_reason" => "Wrong"})

      gone = binned(cancelled)
      bill_fixture(invoice)

      assert {:ok, %EWayBill{status: "Cancelled", deleted_at: nil}} =
               EWayBills.restore_e_way_bill(gone)

      assert length(EWayBills.list_e_way_bills()) == 2
    end
  end

  describe "purge_e_way_bill/2" do
    test "removes the bill and its vehicle history for good" do
      {:ok, bill} =
        EWayBills.update_part_b(bill_fixture(), %{
          "vehicle_number" => "KA05CD9876",
          "mode_of_transport" => "Road"
        })

      gone = binned(bill)

      assert {:ok, _purged} = EWayBills.purge_e_way_bill(gone)

      refute Repo.get(EWayBill, bill.id)
      assert Repo.aggregate(where(PartBUpdate, e_way_bill_id: ^bill.id), :count, :id) == 0
      assert Repo.get(Invoice, bill.invoice_id)
      assert Enum.any?(Audit.list_audit_logs(), &(&1.action == "purge_e_way_bill"))
    end

    # The delete that cannot be undone is only reachable through the Bin.
    test "refuses a bill that is not in the Bin" do
      bill = bill_fixture()

      assert {:error, :not_in_bin} = EWayBills.purge_e_way_bill(bill)
      assert Repo.get(EWayBill, bill.id)
    end
  end

  describe "get_deleted_e_way_bill/1" do
    test "finds only what is in the Bin" do
      kept = bill_fixture()
      gone = binned(bill_fixture())

      assert %EWayBill{invoice: %Invoice{}} = EWayBills.get_deleted_e_way_bill(gone.id)
      assert EWayBills.get_deleted_e_way_bill(to_string(gone.id))
      assert EWayBills.get_deleted_e_way_bill(kept.id) == nil
      assert EWayBills.get_deleted_e_way_bill("not-an-id") == nil
    end
  end
end
