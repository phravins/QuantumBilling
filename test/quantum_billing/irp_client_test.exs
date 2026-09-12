defmodule QuantumBilling.EInvoice.IRPClientTest do
  use QuantumBilling.DataCase, async: true

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
  end
end
