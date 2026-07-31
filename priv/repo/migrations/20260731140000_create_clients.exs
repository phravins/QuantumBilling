defmodule QuantumBilling.Repo.Migrations.CreateClients do
  use Ecto.Migration

  @moduledoc """
  Customers a tenant invoices.

  Like `organization_settings`, this lands in `public` for now and moves into
  the per-tenant schema when tenancy arrives.
  """

  def change do
    create table(:clients) do
      # Basic information
      add :client_type, :string, null: false
      add :name, :string, null: false
      add :display_name, :string
      add :gstin, :string
      add :pan, :string
      add :legal_name, :string
      add :business_type, :string
      add :category, :string

      # Contact
      add :phone_country_code, :string, null: false, default: "+91"
      add :phone, :string
      add :email, :string

      # Billing address
      add :billing_line1, :string
      add :billing_line2, :string
      add :billing_city, :string
      add :billing_state, :string
      add :billing_pin, :string

      # Shipping address. When shipping_same_as_billing is true the billing
      # address is copied across on save, so the stored row is always complete
      # and nothing downstream has to ask which address to read.
      add :shipping_same_as_billing, :boolean, null: false, default: true
      add :shipping_line1, :string
      add :shipping_line2, :string
      add :shipping_city, :string
      add :shipping_state, :string
      add :shipping_pin, :string

      # Trade terms. Money is whole rupees (integers), matching every other
      # amount in the app.
      add :credit_limit, :integer, null: false, default: 0
      add :payment_terms_days, :integer, null: false, default: 30
      add :opening_balance, :integer, null: false, default: 0
      add :notes, :text

      add :status, :string, null: false, default: "Active"

      # Owed by this client. Derived from unpaid invoices once the invoices
      # table exists — it is NOT something the client form collects, and stays
      # 0 until then.
      add :outstanding, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:clients, [:name])

    # A GSTIN identifies exactly one entity, but unregistered clients and
    # consumers legitimately have none. A plain unique index would treat every
    # missing GSTIN as a collision, so this is partial.
    create unique_index(:clients, [:gstin],
             where: "gstin IS NOT NULL",
             name: :clients_gstin_unique
           )
  end
end
