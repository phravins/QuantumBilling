defmodule QuantumBilling.Repo.Migrations.AddQueryIndexesAndIntegrityConstraints do
  use Ecto.Migration

  @moduledoc """
  Indexes for the queries the application actually runs, and check constraints
  for the invariants the changesets already enforce.

  ## Indexes

  The list, dashboard and report pages filter invoices by status and by date
  and order by date — previously a sequential scan of every invoice ever
  issued, which is fine at a thousand rows and not at a million. The composite
  `(status, invoice_date DESC)` serves the filtered list directly; the
  `invoice_date DESC` index serves the unfiltered one. `inserted_at` backs the
  "recently created" ordering the dashboard uses, which is not the same as
  invoice date because an invoice can be back-dated.

  The credential lookups (`razorpay_payment_link_id`, `razorpay_payment_id`)
  are how an incoming payment webhook finds its invoice, so they are indexed
  even though they are only ever read one row at a time: a webhook that
  sequentially scans the invoice table is a denial of service waiting for
  volume.

  ## Constraints

  A changeset validation protects the application's own writes. A check
  constraint protects the table — from a background job, a console session, a
  future code path, or a bug. These mirror validations that already exist, so
  nothing the UI can do starts failing; what changes is that nothing *else* can
  write a negative total or a zero-quantity line either.
  """

  def change do
    # ── Invoices ────────────────────────────────────────────────────────────
    create index(:invoices, [:status])
    create index(:invoices, [:status, :invoice_date])
    create index(:invoices, [:inserted_at])
    create index(:invoices, [:client_name])
    create index(:invoices, [:client_gstin])
    create index(:invoices, [:razorpay_payment_link_id])
    create index(:invoices, [:razorpay_payment_id])

    # An IRN is issued once by the government portal for one invoice. Two rows
    # carrying the same one means a duplicate registration, which is a
    # compliance problem and should fail at the write.
    create unique_index(:invoices, [:irn], where: "irn IS NOT NULL", name: :invoices_irn_unique)

    create constraint(:invoices, :invoices_totals_non_negative,
             check: """
             taxable_value >= 0 AND cgst_amount >= 0 AND sgst_amount >= 0
             AND igst_amount >= 0 AND cess_amount >= 0 AND grand_total >= 0
             AND total_items >= 0 AND total_quantity >= 0
             """
           )

    create constraint(:invoice_items, :invoice_items_quantity_positive, check: "quantity > 0")
    create constraint(:invoice_items, :invoice_items_rate_non_negative, check: "rate >= 0")
    create constraint(:invoice_items, :invoice_items_amount_non_negative, check: "amount >= 0")

    # ── Clients ─────────────────────────────────────────────────────────────
    create index(:clients, [:status])
    create index(:clients, [:email])

    # ── Audit trail ─────────────────────────────────────────────────────────
    # Read newest-first and pruned oldest-first; both walk this index.
    create index(:audit_logs, [:inserted_at])

    # ── Recurring billing ───────────────────────────────────────────────────
    # The due-profile sweep asks for exactly this pair.
    create index(:recurring_profiles, [:status, :next_run_date])

    # ── Settings ────────────────────────────────────────────────────────────
    create constraint(:organization_settings, :organization_settings_numbering_valid,
             check: "invoice_next_number > 0 AND invoice_number_padding BETWEEN 0 AND 11"
           )

    create constraint(:organization_settings, :organization_settings_security_valid,
             check: """
             (session_timeout_minutes IS NULL OR session_timeout_minutes > 0)
             AND (audit_retention_days IS NULL OR audit_retention_days > 0)
             """
           )
  end
end
