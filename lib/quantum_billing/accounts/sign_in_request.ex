defmodule QuantumBilling.Accounts.SignInRequest do
  @moduledoc """
  A sign-in waiting for the device already signed in to allow it.

  Only made under "One device at a time", after the password and any second
  factor were accepted. The waiting browser holds the token in its session;
  only its SHA-256 is stored. The device already signed in sets the status:
  `"approved"` lets the waiting browser in, `"denied"` refuses it.
  """
  use Ecto.Schema

  @schema_prefix "public"
  schema "sign_in_requests" do
    field :token, :binary
    field :device_id, :string
    field :user_agent, :string
    field :ip_address, :string
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime

    belongs_to :user, QuantumBilling.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Whether the request can still be answered or used."
  def live?(%__MODULE__{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now(:second)) == :gt
end
