defmodule QuantumBilling.Repo.TenantMigrations.AddNoteSeriesAndNoteDate do
  use Ecto.Migration

  @moduledoc """
  Credit and debit notes get their own consecutive number series (Rule 53 of
  the CGST Rules) and a date of their own.

  Notes already issued keep their numbers: those are part of the statutory
  record. Their date is taken from when they were saved, as the date in India
  (IST has no daylight saving, so a fixed offset is exact).
  """

  @old_check "invoice_next_number > 0 AND (invoice_number_padding >= 0 AND invoice_number_padding <= 11)"

  @new_check "invoice_next_number > 0 AND credit_note_next_number > 0 AND " <>
               "debit_note_next_number > 0 AND " <>
               "(invoice_number_padding >= 0 AND invoice_number_padding <= 11)"

  def up do
    alter table(:organization_settings) do
      add :credit_note_prefix, :string, null: false, default: "CN"
      add :credit_note_next_number, :integer, null: false, default: 1
      add :debit_note_prefix, :string, null: false, default: "DN"
      add :debit_note_next_number, :integer, null: false, default: 1
    end

    drop constraint(:organization_settings, :organization_settings_numbering_valid)

    create constraint(:organization_settings, :organization_settings_numbering_valid,
             check: @new_check
           )

    alter table(:credit_notes) do
      add :note_date, :date
    end

    flush()

    # Raw SQL skips Ecto's prefix, so the business schema is named.
    execute("""
    UPDATE "#{prefix()}"."credit_notes"
    SET note_date = (inserted_at + interval '5 hours 30 minutes')::date
    """)

    alter table(:credit_notes) do
      modify :note_date, :date, null: false
    end

    create index(:credit_notes, [:note_date])
  end

  def down do
    drop index(:credit_notes, [:note_date])

    alter table(:credit_notes) do
      remove :note_date
    end

    drop constraint(:organization_settings, :organization_settings_numbering_valid)

    create constraint(:organization_settings, :organization_settings_numbering_valid,
             check: @old_check
           )

    alter table(:organization_settings) do
      remove :credit_note_prefix
      remove :credit_note_next_number
      remove :debit_note_prefix
      remove :debit_note_next_number
    end
  end
end
