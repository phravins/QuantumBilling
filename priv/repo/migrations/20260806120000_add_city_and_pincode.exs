defmodule QuantumBilling.Repo.Migrations.AddCityAndPincode do
  @moduledoc """
  City and pincode for the seller and the buyer.

  The GST e-invoice schema (INV-01) requires a location and a PIN for both
  parties.

  `clients` already holds a structured address — `billing_city` and
  `billing_pin` beside the two street lines — so the buyer is covered and is
  left alone. The two gaps are the seller, whose address is a single free-text
  blob on `organization_settings`, and the invoice, which snapshots the client's
  address as one blob and so has nowhere to keep the parts.

  Both new pairs are optional. Existing rows have no value for them and must
  keep working: the blob is still what prints, and the e-invoice export is what
  refuses when a part is missing. Making them required would stop people
  invoicing over a field they have never been asked for.

  The invoice columns are a snapshot, like every other client detail on an
  invoice — see `create_invoices.exs`. An invoice's PIN must stay the one the
  goods actually went to, whatever the client record says afterwards.
  """
  use Ecto.Migration

  def change do
    alter table(:organization_settings) do
      add :city, :string
      add :pincode, :string
    end

    alter table(:invoices) do
      add :client_city, :string
      add :client_pincode, :string
    end
  end
end
