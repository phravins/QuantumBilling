defmodule QuantumBilling.Repo.Migrations.CreateEmailDeliveriesAndWebhookEvents do
  use Ecto.Migration

  @moduledoc """
  Two ledgers the backend needs in order to be answerable for what it did.

  ## `email_deliveries`

  Sending an invoice used to be fire-and-forget: the relay either accepted it
  or the error went to the browser as a flash and vanished. "Did the customer
  get invoice 412?" had no answer anywhere in the system. Every attempt now has
  a row — queued, sent or failed, with the attempt count and the last error —
  written by the mailer worker, so Settings can show a delivery history and a
  failure survives the page that caused it.

  ## `webhook_events`

  A payment provider retries a webhook until it gets a 2xx, and may deliver the
  same event more than once regardless. Without a record of what has already
  been handled, each redelivery re-runs the side effects: the invoice is marked
  paid again and the customer is emailed again. The unique index on
  `(provider, event_id)` is what makes the handler idempotent — a duplicate
  loses the insert and is acknowledged without being processed twice.
  """

  def change do
    create table(:email_deliveries) do
      add :to_email, :string, null: false
      # What was being sent — "invoice", "payment_receipt", "test" — so a
      # failure can be read without opening the job that produced it.
      add :kind, :string, null: false, default: "invoice"
      add :subject, :string

      # Traceability only. A delivery outlives the invoice it refers to, so
      # this is nilified rather than cascaded.
      add :invoice_id, references(:invoices, on_delete: :nilify_all)

      add :status, :string, null: false, default: "queued"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:email_deliveries, [:status])
    create index(:email_deliveries, [:invoice_id])
    create index(:email_deliveries, [:inserted_at])

    create constraint(:email_deliveries, :email_deliveries_status_known,
             check: "status IN ('queued', 'sent', 'failed')"
           )

    create table(:webhook_events) do
      add :provider, :string, null: false
      add :event_id, :string, null: false
      add :event_type, :string
      add :payload, :map, null: false, default: "{}"
      add :status, :string, null: false, default: "processed"
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:webhook_events, [:provider, :event_id])
    create index(:webhook_events, [:inserted_at])
  end
end
