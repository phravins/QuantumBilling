defmodule QuantumBilling.Workers.AuditPruneWorker do
  @moduledoc """
  Enforces the retention window on the tables that grow forever.

  The audit trail, the mail ledger and the webhook receipt log all take one row
  per event and none per user action undone. On a busy installation they are
  the three tables that will be largest a year from now, and the audit trail is
  the one that carries personal data — an IP address against a name — which
  makes "keep everything for ever" a liability rather than thoroughness.

  The window comes from the organisation's `audit_retention_days` setting, so
  this is a policy the business sets rather than a constant in the code. The
  other two ledgers are operational rather than statutory and keep a fixed 90
  days, which is long enough to investigate a delivery failure and short enough
  that the tables stay small.

  Deletion runs in bounded batches. A single `DELETE` over a year of rows takes
  a lock for as long as it takes, which on a large table is long enough to
  matter to everything else running at the time.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Mail.Delivery
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Webhooks.WebhookEvent

  @batch_size 5_000
  @ledger_retention_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    audit_days =
      case args do
        %{"audit_retention_days" => days} when is_integer(days) and days > 0 -> days
        _ -> Settings.get_organization().audit_retention_days || 90
      end

    audit = prune(AuditLog, audit_days)
    deliveries = prune(Delivery, @ledger_retention_days)
    webhooks = prune(WebhookEvent, @ledger_retention_days)

    if audit + deliveries + webhooks > 0 do
      Logger.info(
        "[AuditPruneWorker] pruned #{audit} audit logs, #{deliveries} deliveries, " <>
          "#{webhooks} webhook events"
      )
    end

    {:ok, %{audit_logs: audit, email_deliveries: deliveries, webhook_events: webhooks}}
  end

  @doc """
  Deletes rows of `schema` older than `days`, in batches.

  Returns the number deleted.
  """
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
