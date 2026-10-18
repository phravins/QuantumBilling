defmodule QuantumBilling.EInvoice.IRPClientTest do
  # Not async: live?/0 tests set IRP_* variables, which every process reads.
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.EInvoice.IRPClient
  alias QuantumBilling.Invoices.Invoice

  test "generate_irn/2 simulates realistic IRP response in sandbox mode" do
    invoice = %Invoice{
      invoice_number: "INV-9901",
      company_gstin: "27AABCU9603R1ZM",
      client_gstin: "29AAACI4166L1ZB",
      grand_total: 118_000,
      total_items: 1,
      invoice_date: ~D[2026-03-01],
      items: [%{hsn_sac: "998314"}]
    }

    assert {:ok, result} = IRPClient.generate_irn(invoice, force_sandbox: true)
    assert is_binary(result.irn)
    assert byte_size(result.irn) == 64
    assert is_binary(result.ack_no)
    assert %DateTime{} = result.ack_date
    assert is_binary(result.signed_qr_code)
    assert result.mode == "demo"
  end

  describe "live?/0" do
    setup do
      saved = Map.new(~w(IRP_CLIENT_ID IRP_CLIENT_SECRET IRP_SANDBOX), &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(saved, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end)
    end

    test "is false without credentials, or while IRP_SANDBOX is on" do
      System.delete_env("IRP_CLIENT_ID")
      System.delete_env("IRP_CLIENT_SECRET")
      System.put_env("IRP_SANDBOX", "false")
      refute IRPClient.live?()

      System.put_env("IRP_CLIENT_ID", "id")
      System.put_env("IRP_CLIENT_SECRET", "secret")
      System.put_env("IRP_SANDBOX", "true")
      refute IRPClient.live?()

      System.put_env("IRP_SANDBOX", "false")
      assert IRPClient.live?()
    end
  end
end
