defmodule QuantumBilling.Repo.Migrations.AddInvoiceSortIndexes do
  use Ecto.Migration

  @moduledoc """
  Indexes for the invoice list's slow sort columns.

  ## Why

  The list sorts by `(column, id)` and shows ten rows. Date and number had an
  index to walk in that order; amount, due date and status did not, so each of
  those sorts read every invoice to find the first ten — 436 ms on a million
  invoices. Each index here is walked from either end and stops after a page.

  They are partial on `deleted_at IS NULL`, the condition `Invoice.kept/1` puts
  on every list query, so binned invoices take no space in them.

  ## Why concurrently

  A plain `CREATE INDEX` blocks writes to the table while it builds, which on a
  large account means no invoice can be saved for the duration. Concurrent
  builds cannot run inside a transaction, hence the two attributes.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @columns [:grand_total, :due_date, :status]

  def change do
    for column <- @columns do
      create index(:invoices, [column, :id],
               where: "deleted_at IS NULL",
               name: :"invoices_kept_#{column}_id_index",
               concurrently: true
             )
    end
  end
end
