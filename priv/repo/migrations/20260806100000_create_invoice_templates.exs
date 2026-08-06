defmodule QuantumBilling.Repo.Migrations.CreateInvoiceTemplates do
  @moduledoc """
  Named invoice layouts, each stored as the XML the design pad reads and writes.

  Layouts were previously eleven `doc_*` booleans on the singleton settings row,
  which allowed exactly one design and no way to try another without destroying
  the current one. Those columns are absorbed into a seeded template rather than
  dropped here — the drop is a later migration, so a rollback in between is a
  code revert rather than a data-loss event.

  Nothing seeds this table. `QuantumBilling.Templates.ensure_default/0` creates
  the first row on read, from the organisation's existing settings, following
  the same seed-on-read approach as `Settings.ensure_organization/0`. A data
  migration would have to be correct on a fresh database and a customised one at
  the same time, and could not be tested with the rest of the context.

  Like `clients`, `invoices` and `organization_settings`, this lands in `public`
  for now and moves into the per-tenant schema when tenancy arrives.
  """
  use Ecto.Migration

  def change do
    create table(:invoice_templates) do
      add :name, :string, null: false
      # The layout itself. Text rather than JSONB: the design pad's format is
      # XML, and a parsed mirror alongside it would be a second truth to drift.
      add :layout_xml, :text, null: false
      # Branding, not structure. Read live at render time, so recolouring
      # restyles every invoice issued under this template rather than only the
      # next one — the same rule the document customization columns set.
      add :accent, :string, null: false, default: "#18181b"
      add :is_default, :boolean, null: false, default: false
      # Deleting a template that invoices point at would lose the record of
      # which design they were issued under, so the UI archives instead.
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invoice_templates, [:name], where: "archived_at IS NULL")

    # A real constraint rather than an application convention: with two default
    # rows, "which template does a new invoice get" would be answered by row
    # order. Note this index is not deferrable, so `Templates.set_default/1` has
    # to clear the old default and set the new one inside one transaction.
    create unique_index(:invoice_templates, [:is_default],
             where: "is_default",
             name: :invoice_templates_one_default_index
           )
  end
end
