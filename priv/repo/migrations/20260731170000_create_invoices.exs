defmodule QuantumBilling.Repo.Migrations.CreateInvoices do
  use Ecto.Migration

  @moduledoc """
  GST invoices and their line items.

  Like `clients` and `organization_settings`, these land in `public` for now and
  move into the per-tenant schema when tenancy arrives.

  ## Why the client and company details are copied onto the invoice

  An invoice is a legal document. If a client changes address next month, every
  invoice already issued to them must still show the address that was true when
  it was issued — reading live through `client_id` would silently rewrite
  history. So `client_id` is kept for traceability, and the details that appear
  on the document are snapshotted alongside it. The same applies to the issuing
  company, whose details come from `organization_settings`.

  ## Why the totals are stored

  Recomputing on every read would mean a saved invoice's figures could drift if
  the tax logic ever changes. What was billed is what must be shown.
  """

  def change do
    create table(:invoices) do
      # Consumed from organization_settings.invoice_next_number inside the same
      # transaction that inserts the invoice, so two simultaneous saves cannot
      # be handed the same number.
      add :invoice_number, :string, null: false

      add :invoice_type, :string, null: false, default: "Tax Invoice"
      add :invoice_date, :date, null: false
      add :due_date, :date
      add :payment_terms, :string
      add :place_of_supply, :string, null: false

      # Traceability. Nilified rather than cascaded: deleting a client must not
      # delete the invoices issued to them.
      add :client_id, references(:clients, on_delete: :nilify_all)

      # The client as they were at the moment of issue.
      add :client_name, :string, null: false
      add :client_gstin, :string
      add :client_pan, :string
      add :client_billing_address, :text
      add :client_email, :string
      add :client_state, :string

      # The issuing company as it was at the moment of issue.
      add :company_name, :string
      add :company_address, :text
      add :company_gstin, :string
      add :company_state, :string

      add :remarks, :text
      add :terms, :text

      # Whole rupees, matching every other amount in the application.
      add :total_items, :integer, null: false, default: 0
      add :total_quantity, :integer, null: false, default: 0
      add :taxable_value, :integer, null: false, default: 0
      add :cgst_amount, :integer, null: false, default: 0
      add :sgst_amount, :integer, null: false, default: 0
      add :igst_amount, :integer, null: false, default: 0
      add :cess_amount, :integer, null: false, default: 0
      add :round_off, :integer, null: false, default: 0
      add :grand_total, :integer, null: false, default: 0

      # "Draft" already has a badge clause and is already one of the list
      # page's filter options, so nothing there needs changing.
      add :status, :string, null: false, default: "Draft"

      timestamps(type: :utc_datetime)
    end

    # GST numbering must be unique. The transaction prevents collisions; this
    # is the backstop that makes a slip loud rather than silent.
    create unique_index(:invoices, [:invoice_number])
    create index(:invoices, [:client_id])
    create index(:invoices, [:invoice_date])

    create table(:invoice_items) do
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false

      add :description, :string, null: false
      add :hsn_sac, :string
      add :quantity, :integer, null: false, default: 1
      add :unit, :string, null: false, default: "Nos"
      add :rate, :integer, null: false, default: 0
      add :tax_rate, :integer, null: false, default: 18

      # quantity * rate, before tax. Stored for the same reason the invoice
      # totals are.
      add :amount, :integer, null: false, default: 0

      # Keeps display order stable across adding and removing rows.
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:invoice_items, [:invoice_id])
  end
end
