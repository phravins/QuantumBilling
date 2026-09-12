defmodule QuantumBilling.Repo.Migrations.AddEinvoiceFieldsToInvoices do
  use Ecto.Migration

  def change do
    alter table(:invoices) do
      add :irn, :string
      add :ack_number, :string
      add :ack_date, :utc_datetime
      add :signed_qr_code, :text
      add :signed_invoice, :text
    end

    create index(:invoices, [:irn])
  end
end
