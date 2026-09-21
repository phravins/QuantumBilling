defmodule QuantumBilling.Repo.Migrations.AddSearchAndEWayBillIndexes do
  use Ecto.Migration

  @moduledoc """
  Trigram indexes for the search boxes, and a partial index for the e-way bill
  list.

  ## Why the existing indexes did not help

  Every search box in the application searches for a substring — typing `acme`
  has to find `Acme Corp` and `Global Acme Ltd` alike — so the queries are
  `ILIKE '%acme%'`. A B-tree index can only be walked from the start of the
  value, and a pattern that begins with a wildcard has no start to walk from,
  so `invoices_client_name_index` was never used and every keystroke read the
  whole table. Measured on a hundred thousand invoices, one search was a 196 ms
  sequential scan, and it grows with the table.

  `pg_trgm` indexes the three-character sequences within each value instead, and
  a GIN index over those answers a leading-wildcard `ILIKE` directly.

  ## Why this is wrapped in DO blocks

  `CREATE EXTENSION` needs a privilege that some managed Postgres instances do
  not grant, and an extension that cannot be installed must not stop the
  application from starting. So the extension is attempted, its absence is
  tolerated, and the trigram indexes are created only if it is actually there.
  Search keeps working either way; without the extension it is merely as slow
  as it was before.
  """

  @trigram_indexes [
    {"invoices", "invoice_number"},
    {"invoices", "client_name"},
    {"invoices", "client_gstin"},
    {"invoices", "ewb_number"},
    {"clients", "name"},
    {"clients", "gstin"},
    {"clients", "email"}
  ]

  def up do
    execute("""
    DO $$
    BEGIN
      CREATE EXTENSION IF NOT EXISTS pg_trgm;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pg_trgm is not available; substring search stays sequential';
    END
    $$;
    """)

    for {table, column} <- @trigram_indexes do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
          CREATE INDEX IF NOT EXISTS #{index_name(table, column)}
            ON #{table} USING gin (#{column} gin_trgm_ops);
        END IF;
      END
      $$;
      """)
    end

    # The e-way bill list reads only invoices that have a bill, newest first.
    # Those are a small fraction of the invoice table, and a partial index over
    # just them is both the filter and the ordering.
    create index(:invoices, [:ewb_date, :id],
             where: "ewb_number IS NOT NULL",
             name: :invoices_ewb_date_index
           )

    create index(:invoices, [:ewb_number],
             where: "ewb_number IS NOT NULL",
             name: :invoices_ewb_number_index
           )
  end

  def down do
    drop_if_exists index(:invoices, [:ewb_number], name: :invoices_ewb_number_index)
    drop_if_exists index(:invoices, [:ewb_date, :id], name: :invoices_ewb_date_index)

    for {table, column} <- @trigram_indexes do
      execute("DROP INDEX IF EXISTS #{index_name(table, column)};")
    end
  end

  defp index_name(table, column), do: "#{table}_#{column}_trgm_index"
end
