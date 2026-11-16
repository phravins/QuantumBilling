defmodule QuantumBilling.Repo.TenantMigrations.AddNoteNumberingAndDateToCreditNotes do
  use Ecto.Migration

  @moduledoc """
  Adds configurable sequential numbering series for credit notes and debit notes
  to organization settings, and a statutory note_date to credit_notes.
  """

  def change do
    alter table(:organization_settings) do
      add :credit_note_prefix, :string, default: "CN"
      add :credit_note_next_number, :integer, default: 1
      add :debit_note_prefix, :string, default: "DN"
      add :debit_note_next_number, :integer, default: 1
    end

    alter table(:credit_notes) do
      add :note_date, :date
    end

    # Backfill note_date for existing credit notes from inserted_at converted to IST.
    execute(
      "UPDATE credit_notes SET note_date = ((inserted_at AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata')::date WHERE note_date IS NULL",
      ""
    )
  end
end
