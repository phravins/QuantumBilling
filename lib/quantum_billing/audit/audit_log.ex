defmodule QuantumBilling.Audit.AuditLog do
  @moduledoc """
  Schema for recording immutable audit logs across the application.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_logs" do
    field :action, :string
    field :resource_type, :string
    field :resource_id, :string
    field :details, :map, default: %{}
    field :ip_address, :string

    belongs_to :user, QuantumBilling.Accounts.User

    # Set instead of `user` when the action came through the external API: the
    # key that made the call, so an owner can see which integration did what
    # and revoke the right one.
    belongs_to :api_key, QuantumBilling.ApiKeys.ApiKey

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :user_id,
      :api_key_id,
      :action,
      :resource_type,
      :resource_id,
      :details,
      :ip_address
    ])
    |> validate_required([:action, :resource_type])
  end
end
