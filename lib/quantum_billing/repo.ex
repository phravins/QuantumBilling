defmodule QuantumBilling.Repo do
  use Ecto.Repo,
    otp_app: :quantum_billing,
    adapter: Ecto.Adapters.Postgres
end
