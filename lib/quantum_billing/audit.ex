defmodule QuantumBilling.Audit do
  @moduledoc """
  Context module for managing immutable audit logs.
  """
  import Ecto.Query, warn: false
  alias QuantumBilling.Repo
  alias QuantumBilling.Audit.AuditLog

  @doc """
  Logs a system or user action.
  """
  def log_event(action, resource_type, resource_id \\ nil, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    details = Keyword.get(opts, :details, %{})
    ip_address = Keyword.get(opts, :ip_address)

    %AuditLog{}
    |> AuditLog.changeset(%{
      user_id: user_id,
      action: to_string(action),
      resource_type: to_string(resource_type),
      resource_id: to_string(resource_id),
      details: details,
      ip_address: ip_address
    })
    |> Repo.insert()
  end

  @doc """
  Lists audit logs sorted by most recent.
  """
  def list_audit_logs(limit \\ 100) do
    AuditLog
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(:user)
  end
end
