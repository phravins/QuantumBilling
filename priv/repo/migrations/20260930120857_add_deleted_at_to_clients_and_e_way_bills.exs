defmodule QuantumBilling.Repo.Migrations.AddDeletedAtToClientsAndEWayBills do
  @moduledoc """
  The Bin, for clients and e-way bills.

  Same column and same reasoning as the migration before this one: `deleted_at`
  marks a row as binned and leaves it where it is, so everything that points at
  it still does and a restore is exact.

  ## The two unique indexes

  Both tables have a partial unique index that a binned row must stop holding.

  `clients_gstin_unique` — one client per GSTIN. A binned client that still
  held its GSTIN would make "that GSTIN is already registered to another
  client" the answer to re-adding a customer nobody can see any more.

  `e_way_bills_one_live_bill_per_invoice_index` — one live bill per invoice. A
  binned bill that still held the slot would leave its invoice unable to have
  another raised against it, with nothing on screen to say why.

  So both now also require `deleted_at IS NULL`. The cost is that a restore can
  collide with what took the row's place in the meantime; the contexts turn
  that into an error that says so rather than letting two rows share the slot.
  """
  use Ecto.Migration

  def change do
    alter table(:clients) do
      add :deleted_at, :utc_datetime
    end

    alter table(:e_way_bills) do
      add :deleted_at, :utc_datetime
    end

    create index(:clients, [:deleted_at], where: "deleted_at IS NOT NULL")
    create index(:e_way_bills, [:deleted_at], where: "deleted_at IS NOT NULL")

    # Dropped with their full definitions so that a rollback can put them back.
    drop unique_index(:clients, [:gstin],
           where: "gstin IS NOT NULL",
           name: :clients_gstin_unique
         )

    create unique_index(:clients, [:gstin],
             where: "gstin IS NOT NULL AND deleted_at IS NULL",
             name: :clients_gstin_unique
           )

    drop unique_index(:e_way_bills, [:invoice_id],
           where: "status <> 'Cancelled'",
           name: :e_way_bills_one_live_bill_per_invoice_index
         )

    create unique_index(:e_way_bills, [:invoice_id],
             where: "status <> 'Cancelled' AND deleted_at IS NULL",
             name: :e_way_bills_one_live_bill_per_invoice_index
           )
  end
end
