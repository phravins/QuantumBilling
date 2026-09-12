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

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [:user_id, :action, :resource_type, :resource_id, :details, :ip_address])
    |> validate_required([:action, :resource_type])
  end
end
