defmodule QuantumBilling.Repo.Migrations.AddDocumentCustomizationToOrganizationSettings do
  @moduledoc """
  How an invoice document looks: template, accent colour, logo, and which
  optional columns and blocks appear on it.

  Columns rather than a JSON blob, matching the rest of this table — every
  setting gets a database type and a changeset validation instead of living in
  an untyped bag.

  These are presentation, not invoice data. An invoice snapshots the figures and
  party details it was issued with; the look is read live, so changing a logo
  restyles every invoice rather than only the next one.
  """
  use Ecto.Migration

  def change do
    alter table(:organization_settings) do
      add :doc_template, :string, null: false, default: "Classic"
      add :doc_accent_color, :string, null: false, default: "#18181b"
      add :doc_logo_path, :string
      add :doc_heading, :string
      add :doc_footer_text, :text

      add :doc_show_hsn, :boolean, null: false, default: true
      add :doc_show_unit, :boolean, null: false, default: true
      add :doc_show_tax_rate, :boolean, null: false, default: true
      add :doc_show_remarks, :boolean, null: false, default: true
      add :doc_show_amount_words, :boolean, null: false, default: true

      # Off by default: nothing on the invoice form feeds a cess rate yet, so
      # the row would read a constant zero for most businesses.
      add :doc_show_cess, :boolean, null: false, default: false
    end
  end
end
