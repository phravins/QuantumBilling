defmodule QuantumBilling.EWayBills.NICClientTest do
  @moduledoc """
  Demo and live e-way bills.

  The client used to answer a live portal's timeout or error page with a
  locally minted number and report success, so a user with live access could
  be handed a bill the government had never seen. A configured portal that
  does not answer is now an error, nothing is recorded, and every bill says
  which mode issued it.

  Requests are intercepted with `Req.Test`.
  """
  # Not async: sets NIC_EWB_API_URL and Req's default options, which every
  # process reads.
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.EWayBills
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.Invoices.Invoice

  defp invoice_fixture do
    Repo.insert!(%Invoice{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_state: "Karnataka",
      client_name: "Acme India Pvt Ltd",
      client_gstin: "27AAAAA0000A1Z5",
      taxable_value: 100_000,
      grand_total: 118_000
    })
  end

  defp go_live do
    System.put_env("NIC_EWB_API_URL", "https://nic.example.test")
    on_exit(fn -> System.delete_env("NIC_EWB_API_URL") end)

    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)
  end

  describe "without a portal configured" do
    test "mints a demo bill and says so" do
      refute NICClient.live?()

      assert {:ok, attrs} = NICClient.generate_ewb(invoice_fixture(), %{"distance_km" => "100"})
      assert attrs.portal_mode == "demo"
      assert attrs.ewb_number =~ ~r/^\d{12}$/
    end
  end

  describe "with a portal configured" do
    setup do
      go_live()
      :ok
    end

    test "records the portal's number as live" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"status" => "1", "ewbNo" => 321_000_000_001})
      end)

      assert NICClient.live?()
      assert {:ok, bill} = EWayBills.generate_e_way_bill(invoice_fixture(), %{})
      assert bill.ewb_number == "321000000001"
      assert bill.portal_mode == "live"
      refute EWayBill.demo?(bill)
    end

    test "a portal that fails is an error, and no bill is recorded" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      assert {:error, :portal_unavailable} =
               EWayBills.generate_e_way_bill(invoice_fixture(), %{})

      assert Repo.aggregate(EWayBill, :count) == 0
    end

    test "a portal that cannot be reached is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, :portal_unavailable} = NICClient.generate_ewb(invoice_fixture(), %{})
    end

    test "an answer the client does not understand is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"status" => "0"}) end)

      assert {:error, :unexpected_response} = NICClient.generate_ewb(invoice_fixture(), %{})
    end

    test "the portal's own refusal is passed on" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"status" => "0", "error" => "Invalid GSTIN"})
      end)

      assert {:error, "Invalid GSTIN"} = NICClient.generate_ewb(invoice_fixture(), %{})
    end

    # A demo bill does not exist on the portal; cancelling it there would fail.
    test "cancelling a demo bill does not call the portal" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :portal_called)
        Plug.Conn.send_resp(conn, 500, "")
      end)

      bill = %EWayBill{ewb_number: "191012345678", portal_mode: "demo"}

      assert {:ok, %{"ewbNo" => "191012345678"}} =
               NICClient.cancel_ewb(bill, %{"cancellation_reason" => "Order cancelled"})

      refute_received :portal_called
    end

    test "cancelling a live bill while the portal is down is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 502, "") end)

      bill = %EWayBill{ewb_number: "321000000001", portal_mode: "live"}

      assert {:error, :portal_unavailable} =
               NICClient.cancel_ewb(bill, %{"cancellation_reason" => "Order cancelled"})
    end
  end

  test "a live bill cannot be changed once no portal is configured" do
    bill = %EWayBill{ewb_number: "321000000001", portal_mode: "live"}

    assert {:error, :portal_not_configured} =
             NICClient.update_part_b(bill, %{"vehicle_number" => "MH01AA0001"})

    assert NICClient.error_message(:portal_not_configured) =~ "Nothing was changed"
  end
end
