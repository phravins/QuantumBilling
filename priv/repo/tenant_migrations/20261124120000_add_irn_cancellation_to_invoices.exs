defmodule QuantumBilling.Repo.TenantMigrations.AddIrnCancellationToInvoices do
  use Ecto.Migration

  @moduledoc """
  Adds statutory e-invoice (IRN) cancellation metadata to the invoices table.
  """

  def change do
    alter table(:invoices) do
      add :irn_cancelled_at, :utc_datetime
      add :irn_cancellation_reason, :string
      add :irn_cancellation_remarks, :string
    end
  end
end
