defmodule QuantumBilling.AuditTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Audit

  test "log_event/4 creates an immutable audit log record" do
    assert {:ok, log} =
             Audit.log_event(:generate_irn, "Invoice", "INV-1001", details: %{status: "success"})

    assert log.action == "generate_irn"
    assert log.resource_type == "Invoice"
    assert log.resource_id == "INV-1001"
    assert log.details["status"] == "success" or log.details[:status] == "success"

    logs = Audit.list_audit_logs()
    assert length(logs) >= 1
  end
end
