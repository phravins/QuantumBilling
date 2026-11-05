defmodule QuantumBilling.Workers.AuditPruneWorker do
  @moduledoc """
  Prunes the tables that grow forever, in bounded batches to avoid long locks.

  The audit trail keeps the organisation's `audit_retention_days`. The mail
  ledger, webhook receipts and notifications keep 90 days, and only read
  notifications are pruned.
  """
  use QuantumBilling.Worker, sweep: true, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias QuantumBilling.ApiKeys
  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Mail.Delivery
  alias QuantumBilling.Notifications
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Webhooks.WebhookEvent

  @batch_size 5_000
  @ledger_retention_days 90

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: args}) do
    audit_days =
      case args do
        %{"audit_retention_days" => days} when is_integer(days) and days > 0 -> days
        _ -> Settings.get_organization().audit_retention_days || 90
      end

    audit = prune(AuditLog, audit_days)
    deliveries = prune(Delivery, @ledger_retention_days)
    webhooks = prune(WebhookEvent, @ledger_retention_days)
    # Outgoing delivery log: kept as long as the incoming one.
    deliveries_out = prune(QuantumBilling.Webhooks.Delivery, @ledger_retention_days)
    # Through the context: only read notifications may be pruned.
    notifications = Notifications.prune(@ledger_retention_days)
    # Stored API responses for replay. A day's lifetime, not 90: they hold
    # whole response bodies, and nothing replays them after that anyway.
    {:ok, idempotency} = ApiKeys.prune_idempotency_keys(Repo.business())

    if audit + deliveries + webhooks + deliveries_out + notifications + idempotency > 0 do
      Logger.info(
        "[AuditPruneWorker] pruned #{audit} audit logs, #{deliveries} deliveries, " <>
          "#{webhooks} webhook events, #{deliveries_out} webhook deliveries, " <>
          "#{notifications} notifications, " <>
          "#{idempotency} API idempotency records"
      )
    end

    {:ok,
     %{
       audit_logs: audit,
       email_deliveries: deliveries,
       webhook_events: webhooks,
       webhook_deliveries: deliveries_out,
       notifications: notifications,
       api_idempotency_keys: idempotency
     }}
  end

  @doc "Deletes rows of `schema` older than `days`, in batches. Returns the count deleted."
  def prune(schema, days) when is_integer(days) and days > 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    delete_in_batches(schema, cutoff, 0)
  end

  defp delete_in_batches(schema, cutoff, deleted) do
    ids =
      Repo.all(
        from row in schema,
          where: row.inserted_at < ^cutoff,
          select: row.id,
          limit: @batch_size
      )

    case ids do
      [] ->
        deleted

      ids ->
        {count, _} = Repo.delete_all(from row in schema, where: row.id in ^ids)
        delete_in_batches(schema, cutoff, deleted + count)
    end
  end
end
