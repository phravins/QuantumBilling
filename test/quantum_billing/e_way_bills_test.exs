defmodule QuantumBilling.EWayBillsTest do
  @moduledoc """
  The e-way bill context, now that a bill is a row rather than eight columns on
  the invoice it was raised against.

  What that buys, and what is tested here: an invoice can carry a cancelled
  bill and the one raised to replace it; a cancellation has a time, a reason
  and a window; and a change of vehicle is recorded as a leg of a journey
  instead of overwriting the only vehicle the bill ever had.
  """
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.EWayBills
  alias QuantumBilling.EWayBills.EWayBill
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

  defp bill_fixture(invoice \\ nil, params \\ %{}) do
    invoice = invoice || invoice_fixture()

    {:ok, bill} =
      EWayBills.generate_e_way_bill(
        invoice,
        Map.merge(%{"distance_km" => "180", "vehicle_number" => "MH04CD5678"}, params)
      )

    bill
  end

  describe "generate_e_way_bill/2" do
    test "raises a bill against the invoice and returns it, not the invoice" do
      invoice = invoice_fixture()

      assert {:ok, %EWayBill{} = bill} =
               EWayBills.generate_e_way_bill(invoice, %{
                 "distance_km" => "180",
                 "vehicle_number" => "MH04CD5678"
               })

      assert bill.ewb_number =~ ~r/^\d{12}$/
      assert bill.distance_km == 180
      assert bill.vehicle_number == "MH04CD5678"
      assert bill.status == "Active"
      assert bill.invoice_id == invoice.id
      # Preloaded, because every caller goes on to print or name the document.
      assert bill.invoice.invoice_number == invoice.invoice_number
    end

    # Rule 138(10): one day per 200 km or part thereof, expiring at midnight of
    # the day following generation rather than at the generation hour.
    test "dates the validity by the distance" do
      short = bill_fixture(nil, %{"distance_km" => "180"})
      long = bill_fixture(nil, %{"distance_km" => "620"})

      assert NaiveDateTime.to_date(short.valid_until) == Date.add(Date.utc_today(), 1)
      assert NaiveDateTime.to_date(long.valid_until) == Date.add(Date.utc_today(), 4)
      assert NaiveDateTime.to_time(short.valid_until) == ~T[23:59:59]
    end

    test "refuses an invoice that already carries a live bill" do
      invoice = invoice_fixture()
      _first = bill_fixture(invoice)

      assert {:error, :already_issued} = EWayBills.generate_e_way_bill(invoice, %{})
    end

    test "refuses a cancelled invoice" do
      invoice = invoice_fixture(%{status: "Cancelled"})

      assert {:error, :cancelled} = EWayBills.generate_e_way_bill(invoice, %{})
    end

    # The point of the partial unique index rather than a plain one: a spent
    # number does not stop the consignment being re-billed.
    test "allows a fresh bill once the previous one is cancelled" do
      invoice = invoice_fixture()
      first = bill_fixture(invoice)

      {:ok, _cancelled} =
        EWayBills.cancel_e_way_bill(first, %{"cancellation_reason" => "Data Entry Mistake"})

      assert {:ok, second} = EWayBills.generate_e_way_bill(invoice, %{"distance_km" => "180"})
      assert second.id != first.id
      assert EWayBills.live_bill_for_invoice(invoice.id).id == second.id
    end
  end

  describe "cancel_e_way_bill/2" do
    test "records the time and the reason" do
      bill = bill_fixture()

      assert {:ok, cancelled} =
               EWayBills.cancel_e_way_bill(bill, %{"cancellation_reason" => "Order Cancelled"})

      assert cancelled.status == "Cancelled"
      assert cancelled.cancellation_reason == "Order Cancelled"
      assert %DateTime{} = cancelled.cancelled_at
      assert EWayBills.status(cancelled) == "Cancelled"
    end

    test "requires a reason" do
      bill = bill_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} = EWayBills.cancel_e_way_bill(bill, %{})

      assert "a reason is required to cancel an e-way bill" in errors_on(changeset).cancellation_reason
    end

    test "refuses a bill that is already cancelled" do
      bill = bill_fixture()

      {:ok, cancelled} =
        EWayBills.cancel_e_way_bill(bill, %{"cancellation_reason" => "Duplicate"})

      assert {:error, :already_cancelled} =
               EWayBills.cancel_e_way_bill(cancelled, %{"cancellation_reason" => "Duplicate"})
    end

    # Rule 138(9) gives twenty-four hours from generation. Past that the number
    # stays spent at the portal, and recording a cancellation the portal did
    # not accept would make this table disagree with the government's.
    test "refuses a bill whose twenty-four hours have passed" do
      stale =
        bill_fixture()
        |> Ecto.Changeset.change(inserted_at: hours_ago(25))
        |> Repo.update!()

      refute EWayBills.cancellable?(stale)

      assert {:error, :window_closed} =
               EWayBills.cancel_e_way_bill(stale, %{"cancellation_reason" => "Duplicate"})
    end

    test "allows one raised an hour ago" do
      recent =
        bill_fixture()
        |> Ecto.Changeset.change(inserted_at: hours_ago(1))
        |> Repo.update!()

      assert EWayBills.cancellable?(recent)
    end
  end

  describe "update_part_b/2" do
    test "moves the bill onto the new vehicle and keeps both legs" do
      bill = bill_fixture()

      assert {:ok, updated} =
               EWayBills.update_part_b(bill, %{
                 "vehicle_number" => "KA05CD9876",
                 "mode_of_transport" => "Road",
                 "place" => "Belgaum",
                 "reason" => "Breakdown"
               })

      assert updated.vehicle_number == "KA05CD9876"

      # The first leg is the vehicle the bill was raised with. Nothing records
      # it while it is the only one, so the first update writes it down before
      # overwriting it — otherwise the journey would begin at its second
      # vehicle, which is exactly the history a check post asks for.
      assert [first, second] = updated.part_b_updates
      assert first.vehicle_number == "MH04CD5678"
      assert second.vehicle_number == "KA05CD9876"
      assert second.place == "Belgaum"
      assert second.reason == "Breakdown"
    end

    test "appends a third leg without re-recording the first" do
      bill = bill_fixture()

      {:ok, bill} =
        EWayBills.update_part_b(bill, %{
          "vehicle_number" => "KA05CD9876",
          "mode_of_transport" => "Road"
        })

      {:ok, bill} =
        EWayBills.update_part_b(bill, %{
          "vehicle_number" => "TN09EF4321",
          "mode_of_transport" => "Road"
        })

      assert Enum.map(bill.part_b_updates, & &1.vehicle_number) ==
               ["MH04CD5678", "KA05CD9876", "TN09EF4321"]
    end

    test "requires a vehicle" do
      bill = bill_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               EWayBills.update_part_b(bill, %{"mode_of_transport" => "Road"})

      assert "can't be blank" in errors_on(changeset).vehicle_number
    end

    test "refuses a cancelled bill" do
      bill = bill_fixture()

      {:ok, cancelled} =
        EWayBills.cancel_e_way_bill(bill, %{"cancellation_reason" => "Duplicate"})

      assert {:error, :already_cancelled} =
               EWayBills.update_part_b(cancelled, %{"vehicle_number" => "KA05CD9876"})
    end

    test "refuses an expired bill" do
      expired =
        bill_fixture()
        |> Ecto.Changeset.change(valid_until: ~N[2020-01-01 00:00:00])
        |> Repo.update!()

      assert {:error, :expired} =
               EWayBills.update_part_b(expired, %{"vehicle_number" => "KA05CD9876"})
    end
  end

  describe "status/1" do
    test "derives expiry from the clock rather than storing it" do
      bill = bill_fixture()
      assert EWayBills.status(bill) == "Active"

      expired = %{bill | valid_until: ~N[2020-01-01 00:00:00]}
      assert EWayBills.status(expired) == "Expired"

      # Cancellation is stored, and outranks the clock.
      assert EWayBills.status(%{expired | status: "Cancelled"}) == "Cancelled"
    end
  end

  describe "page/1" do
    test "returns the same shape the invoice list paginates with" do
      for _ <- 1..3, do: bill_fixture()

      assert %{rows: rows, total: 3, page: 1, per_page: 2, total_pages: 2} =
               EWayBills.page(page: 1, per_page: 2)

      assert length(rows) == 2
    end

    test "searches the EWB number, the document number and the consignee" do
      northwind = bill_fixture(invoice_fixture(%{client_name: "Northwind Traders"}))
      _contoso = bill_fixture(invoice_fixture(%{client_name: "Contoso Logistics"}))

      assert %{total: 1, rows: [row]} = EWayBills.page(search: "Northwind")
      assert row.to_party == "Northwind Traders"

      assert %{total: 1} = EWayBills.page(search: northwind.ewb_number)
      assert %{total: 1} = EWayBills.page(search: northwind.invoice.invoice_number)
      assert %{total: 0} = EWayBills.page(search: "nothing here")
    end

    test "filters on the derived status" do
      _active = bill_fixture()

      _expired =
        bill_fixture()
        |> Ecto.Changeset.change(valid_until: ~N[2020-01-01 00:00:00])
        |> Repo.update!()

      {:ok, _cancelled} =
        EWayBills.cancel_e_way_bill(bill_fixture(), %{"cancellation_reason" => "Duplicate"})

      assert %{total: 3} = EWayBills.page(status: "All Status")
      assert %{total: 1} = EWayBills.page(status: "Active")
      assert %{total: 1} = EWayBills.page(status: "Expired")
      assert %{total: 1} = EWayBills.page(status: "Cancelled")
    end

    test "ignores a sort field it does not recognise" do
      bill_fixture()

      assert %{total: 1} = EWayBills.page(sort_field: :not_a_column)
    end
  end

  describe "export_rows/1" do
    test "takes the filters but not the pagination" do
      for _ <- 1..12, do: bill_fixture()

      assert %{rows: rows, total: 12} = EWayBills.page(per_page: 10)
      assert length(rows) == 10

      assert length(EWayBills.export_rows([])) == 12
    end

    test "honours the search it is given" do
      bill_fixture(invoice_fixture(%{client_name: "Northwind Traders"}))
      bill_fixture(invoice_fixture(%{client_name: "Contoso Logistics"}))

      assert [row] = EWayBills.export_rows(search: "Northwind")
      assert row.to_party == "Northwind Traders"
    end
  end

  defp hours_ago(hours) do
    DateTime.utc_now() |> DateTime.add(-hours, :hour) |> DateTime.truncate(:second)
  end
end
