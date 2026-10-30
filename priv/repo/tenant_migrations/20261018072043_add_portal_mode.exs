defmodule QuantumBilling.Repo.TenantMigrations.AddPortalMode do
  use Ecto.Migration

  @moduledoc """
  Records whether each e-way bill and IRN came from the government portal or
  was generated locally in demo mode. Without it a demo number is
  indistinguishable from a filed one once saved.

  Existing e-way bills become `"demo"`: nothing marks a simulated bill number,
  and live NIC access was not configured before this column existed. Existing
  IRNs can be told apart: the simulator signs them `MOCK_SIGNED_JWT_…`.
  """

  def up do
    schema = prefix()

    alter table(:e_way_bills) do
      add :portal_mode, :string, null: false, default: "demo"
    end

    alter table(:invoices) do
      add :irn_mode, :string
    end

    flush()

    execute("""
    UPDATE "#{schema}"."invoices"
    SET irn_mode = CASE WHEN signed_invoice LIKE 'MOCK_SIGNED_JWT_%' THEN 'demo' ELSE 'live' END
    WHERE irn IS NOT NULL
    """)

    create constraint(:e_way_bills, :e_way_bills_portal_mode_valid,
             check: "portal_mode IN ('demo', 'live')"
           )

    create constraint(:invoices, :invoices_irn_mode_valid,
             check: "irn_mode IS NULL OR irn_mode IN ('demo', 'live')"
           )
  end

  def down do
    drop constraint(:invoices, :invoices_irn_mode_valid)
    drop constraint(:e_way_bills, :e_way_bills_portal_mode_valid)

    alter table(:invoices) do
      remove :irn_mode
    end

    alter table(:e_way_bills) do
      remove :portal_mode
    end
  end
end
