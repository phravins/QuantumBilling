defmodule QuantumBilling.Workers.AuditPruneWorkerTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Audit
  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Mail
  alias QuantumBilling.Settings
  alias QuantumBilling.Webhooks
  alias QuantumBilling.Webhooks.WebhookEvent
  alias QuantumBilling.Workers.AuditPruneWorker

  defp age(schema, id, days) do
    stamp =
      DateTime.utc_now()
      |> DateTime.add(-days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    Repo.update_all(
      from(row in schema, where: row.id == ^id),
      set: [inserted_at: stamp]
    )
  end

  test "deletes audit logs past the organisation's retention window" do
    {:ok, old} = Audit.log_event(:payment_received, "Invoice", 1)
    {:ok, recent} = Audit.log_event(:payment_received, "Invoice", 2)

    age(AuditLog, old.id, 120)

    {:ok, _organization} =
      Settings.update_section(
        Settings.get_organization(),
        %{"audit_retention_days" => 90},
        :security
      )

    assert {:ok, result} = AuditPruneWorker.perform(%Oban.Job{args: %{}})

    assert result.audit_logs == 1
    assert Repo.get(AuditLog, old.id) == nil
    assert Repo.get(AuditLog, recent.id)
  end

  test "the window can be given explicitly, for a one-off run" do
    {:ok, log} = Audit.log_event(:login, "User", 1)
    age(AuditLog, log.id, 10)

    assert {:ok, %{audit_logs: 1}} =
             AuditPruneWorker.perform(%Oban.Job{args: %{"audit_retention_days" => 7}})
  end

  test "prunes the mail and webhook ledgers on their own fixed window" do
    {:ok, delivery} = Mail.record_queued(%{to_email: "old@example.com"})
    {:ok, event} = Webhooks.claim("razorpay", "evt_old", %{})

    age(QuantumBilling.Mail.Delivery, delivery.id, 200)
    age(WebhookEvent, event.id, 200)

    assert {:ok, result} = AuditPruneWorker.perform(%Oban.Job{args: %{}})

    assert result.email_deliveries == 1
    assert result.webhook_events == 1
    assert Mail.get_delivery(delivery.id) == nil
  end

  test "deletes nothing when everything is inside the window" do
    {:ok, _log} = Audit.log_event(:login, "User", 1)

    assert {:ok, %{audit_logs: 0, email_deliveries: 0, webhook_events: 0}} =
             AuditPruneWorker.perform(%Oban.Job{args: %{}})
  end
end
