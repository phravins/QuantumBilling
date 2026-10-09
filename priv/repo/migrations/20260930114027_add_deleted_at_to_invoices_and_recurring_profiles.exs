defmodule QuantumBilling.Repo.Migrations.AddDeletedAtToInvoicesAndRecurringProfiles do
  @moduledoc """
  The Bin.

  Deleting an invoice or a recurring profile used to be a `DELETE`: one click,
  past a confirmation nobody reads, and the row — with its line items, its
  e-way bills and its credit notes, which cascade — was gone for good. For a
  book of statutory documents that is the wrong default.

  `deleted_at` marks a row as binned instead. It is a flag on the row rather
  than a copy of the row somewhere else, because everything that hangs off an
  invoice points at its id: leaving the row where it is means a restore is
  exact, with nothing to move back and nothing to get out of step.

  Invoice designs need no column. They already have `archived_at`, which has
  meant "removed from the list, kept for the record" since they were created.

  The indexes are partial, over binned rows only. The Bin page reads "every
  binned row, newest first", and binned rows are a sliver of the table; an
  index over all of it would be paying to index the rows nobody asks for.
  """
  use Ecto.Migration

  def change do
    alter table(:invoices) do
      add :deleted_at, :utc_datetime
    end

    alter table(:recurring_profiles) do
      add :deleted_at, :utc_datetime
    end

    create index(:invoices, [:deleted_at], where: "deleted_at IS NOT NULL")
    create index(:recurring_profiles, [:deleted_at], where: "deleted_at IS NOT NULL")
  end
end
