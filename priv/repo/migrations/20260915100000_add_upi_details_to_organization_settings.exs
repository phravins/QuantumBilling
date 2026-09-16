defmodule QuantumBilling.Repo.Migrations.AddUpiDetailsToOrganizationSettings do
  use Ecto.Migration

  @moduledoc """
  The UPI address customers actually pay into.

  The payment QR on every invoice was built from the organisation's *contact
  email* as the payee VPA, because there was nowhere to put a real one. UPI
  apps reject that — a VPA is `name@handle` issued by a bank or PSP — so the
  code scanned into an error on every invoice.

  Not a credential: a VPA is published on the invoice by design, so it stays a
  readable column rather than joining the encrypted ones.
  """

  def change do
    alter table(:organization_settings) do
      add :upi_vpa, :string
      # Optional. Banks show the payee name from their own records anyway, but
      # a trading name here is what the payer sees while confirming.
      add :upi_payee_name, :string
    end
  end
end
