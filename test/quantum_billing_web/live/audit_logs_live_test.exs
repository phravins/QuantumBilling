defmodule QuantumBillingWeb.AuditLogsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias QuantumBilling.Audit

  setup :register_and_log_in_user

  test "renders audit logs dashboard and filters", %{conn: conn} do
    Audit.log_event(:generate_irn, "Invoice", "INV-1001", details: %{test: true})

    {:ok, view, html} = live(conn, ~p"/settings/audit-logs")
    assert html =~ "Audit Trail"
    assert html =~ "generate_irn"

    # Filter actions
    assert render_change(view, "filter", %{"action" => "generate_irn"}) =~ "generate_irn"
  end
end
