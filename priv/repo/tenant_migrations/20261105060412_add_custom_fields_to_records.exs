defmodule QuantumBilling.Repo.TenantMigrations.AddCustomFieldsToRecords do
  use Ecto.Migration

  @moduledoc "A `custom_fields` map on every record type that can carry custom fields."

  @tables ~w(clients invoices invoice_items credit_notes e_way_bills recurring_profiles)a

  def change do
    for table <- @tables do
      alter table(table) do
        add :custom_fields, :map, null: false, default: %{}
      end
    end

    # For the list filters, which match with @>.
    create index(:clients, ["custom_fields jsonb_path_ops"],
             using: "GIN",
             name: :clients_custom_fields_index
           )

    create index(:invoices, ["custom_fields jsonb_path_ops"],
             using: "GIN",
             name: :invoices_custom_fields_index
           )
  end
end
