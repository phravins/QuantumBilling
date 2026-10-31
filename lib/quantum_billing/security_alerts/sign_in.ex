defmodule QuantumBilling.SecurityAlerts.SignIn do
  @moduledoc "One successful sign-in: who, from which address, with what."
  use Ecto.Schema

  @schema_prefix "public"
  schema "user_sign_ins" do
    field :ip_address, :string
    field :user_agent, :string
    field :method, :string

    belongs_to :user, QuantumBilling.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
