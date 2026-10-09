defmodule QuantumBilling.Repo.Migrations.CreateEWayBills do
  @moduledoc """
  Gives e-way bills a table of their own.

  ## Why

  Until now a bill lived as eight columns on `invoices` — `ewb_number`,
  `ewb_date`, `ewb_valid_until`, `distance_km`, `transporter_id`,
  `transporter_name`, `vehicle_number`, `mode_of_transport`. That shape makes
  two things the law requires impossible to record:

    * **Cancellation.** Rule 138(9) allows a bill to be cancelled within 24
      hours and a fresh one raised against the same document. With the number
      on the invoice, cancelling means erasing the old number — the audit trail
      the rule exists to create is exactly what gets destroyed.

    * **Part-B updates.** Form GST EWB-01 prints Part-B as a *table* of vehicle
      entries, because a consignment that changes vehicle mid-transit must have
      each leg recorded. One `vehicle_number` column can hold one leg.

  So: a bill is a row, cancelled bills stay, and Part-B updates accumulate in a
  child table.

  ## The partial unique index

  `invoice_id` is unique only `WHERE status <> 'Cancelled'`. That is the rule
  "one live bill per document" expressed in the schema rather than in a hidden
  button, while still allowing the re-issue that Rule 138(9) contemplates.

  ## Backfill

  Every invoice that already carries an `ewb_number` becomes a row here. The
  columns themselves are dropped in the following migration, deliberately not
  this one, so the copy can be checked against live data first and there is a
  real point to roll back to.
  """
  use Ecto.Migration

  def up do
    create table(:e_way_bills) do
      add :ewb_number, :string, null: false
      add :ewb_date, :date, null: false
      add :valid_until, :naive_datetime, null: false
      add :status, :string, null: false, default: "Active"
      add :distance_km, :integer, null: false
      add :mode_of_transport, :string, null: false, default: "Road"
      add :vehicle_number, :string
      add :transporter_id, :string
      add :transporter_name, :string
      add :cancelled_at, :utc_datetime
      add :cancellation_reason, :string

      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:e_way_bills, [:ewb_number])
    create index(:e_way_bills, [:invoice_id])
    create index(:e_way_bills, [:status])
    # The list page's default sort, id-tied so paging is stable.
    create index(:e_way_bills, [:ewb_date, :id])

    create unique_index(:e_way_bills, [:invoice_id],
             where: "status <> 'Cancelled'",
             name: :e_way_bills_one_live_bill_per_invoice_index
           )

    create table(:e_way_bill_part_b_updates) do
      add :vehicle_number, :string, null: false
      add :mode_of_transport, :string, null: false, default: "Road"
      add :place, :string
      add :reason, :string
      add :updated_on, :utc_datetime, null: false

      add :e_way_bill_id, references(:e_way_bills, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:e_way_bill_part_b_updates, [:e_way_bill_id])

    # Backfill: a bill with no stored validity gets one day from issue, Rule 138(10)'s floor.
    execute("""
    INSERT INTO e_way_bills (
      ewb_number, ewb_date, valid_until, status, distance_km, mode_of_transport,
      vehicle_number, transporter_id, transporter_name, invoice_id,
      inserted_at, updated_at
    )
    SELECT
      i.ewb_number,
      COALESCE(i.ewb_date, i.invoice_date, CURRENT_DATE),
      COALESCE(
        i.ewb_valid_until,
        (COALESCE(i.ewb_date, i.invoice_date, CURRENT_DATE) + INTERVAL '1 day')::timestamp(0)
      ),
      CASE WHEN i.status = 'Cancelled' THEN 'Cancelled' ELSE 'Active' END,
      COALESCE(i.distance_km, 0),
      COALESCE(i.mode_of_transport, 'Road'),
      i.vehicle_number,
      i.transporter_id,
      i.transporter_name,
      i.id,
      NOW() AT TIME ZONE 'UTC',
      NOW() AT TIME ZONE 'UTC'
    FROM invoices i
    WHERE i.ewb_number IS NOT NULL AND i.ewb_number <> ''
    """)
  end

  def down do
    # Put the data back where it came from before the tables go, so rolling
    # this migration back does not silently discard every bill.
    execute("""
    UPDATE invoices i
    SET ewb_number = b.ewb_number,
        ewb_date = b.ewb_date,
        ewb_valid_until = b.valid_until,
        distance_km = b.distance_km,
        mode_of_transport = b.mode_of_transport,
        vehicle_number = b.vehicle_number,
        transporter_id = b.transporter_id,
        transporter_name = b.transporter_name
    FROM e_way_bills b
    WHERE b.invoice_id = i.id AND b.status <> 'Cancelled'
    """)

    drop table(:e_way_bill_part_b_updates)
    drop table(:e_way_bills)
  end
end
