defmodule QuantumBilling.Repo.Migrations.DropEWayBillColumnsFromInvoices do
  @moduledoc """
  Removes the eight e-way bill columns from `invoices`, now that
  `e_way_bills` holds them.

  Separate from the migration that created the table so the backfill can be
  verified against live data before the source columns go, and so a rollback
  has somewhere to land.

  The search indexes move with the data: the trigram index on
  `invoices.ewb_number` is recreated on `e_way_bills.ewb_number`, inside the
  same conditional block the original used, because `pg_trgm` is deliberately
  optional on instances that do not grant `CREATE EXTENSION`.
  """
  use Ecto.Migration

  @columns ~w(ewb_number ewb_date ewb_valid_until distance_km transporter_id
              transporter_name vehicle_number mode_of_transport)a

  def up do
    drop_if_exists index(:invoices, [:ewb_number], name: :invoices_ewb_number_index)
    drop_if_exists index(:invoices, [:ewb_date, :id], name: :invoices_ewb_date_index)
    execute("DROP INDEX IF EXISTS invoices_ewb_number_trgm_index;")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        CREATE INDEX IF NOT EXISTS e_way_bills_ewb_number_trgm_index
          ON e_way_bills USING gin (ewb_number gin_trgm_ops);
      END IF;
    END
    $$;
    """)

    alter table(:invoices) do
      for column <- @columns, do: remove(column)
    end
  end

  def down do
    alter table(:invoices) do
      add :ewb_number, :string
      add :ewb_date, :date
      add :ewb_valid_until, :naive_datetime
      add :distance_km, :integer
      add :transporter_id, :string
      add :transporter_name, :string
      add :vehicle_number, :string
      add :mode_of_transport, :string, default: "Road"
    end

    execute("DROP INDEX IF EXISTS e_way_bills_ewb_number_trgm_index;")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        CREATE INDEX IF NOT EXISTS invoices_ewb_number_trgm_index
          ON invoices USING gin (ewb_number gin_trgm_ops);
      END IF;
    END
    $$;
    """)

    create index(:invoices, [:ewb_date, :id],
             where: "ewb_number IS NOT NULL",
             name: :invoices_ewb_date_index
           )

    create index(:invoices, [:ewb_number],
             where: "ewb_number IS NOT NULL",
             name: :invoices_ewb_number_index
           )
  end
end
