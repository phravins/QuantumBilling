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
    api_key_id = Keyword.get(opts, :api_key_id)
    details = Keyword.get(opts, :details, %{})
    ip_address = Keyword.get(opts, :ip_address)

    result =
      %AuditLog{}
      |> AuditLog.changeset(%{
        user_id: user_id,
        api_key_id: api_key_id,
        action: to_string(action),
        resource_type: to_string(resource_type),
        resource_id: to_string(resource_id),
        details: details,
        ip_address: ip_address
      })
      |> Repo.insert()

    case result do
      {:ok, log} ->
        log = Repo.preload(log, :user)

        QuantumBilling.Events.broadcast(
          QuantumBilling.Events.audit_logs_topic(),
          {:audit_log_created, log}
        )

        {:ok, log}

      error ->
        error
    end
  end

  @doc """
  Lists audit logs sorted by most recent.
  """
  def list_audit_logs(limit \\ 100) do
    AuditLog
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(:user)
  end

  @doc """
  The newest `limit` actions taken by one user, for their profile page.
  """
  def recent_for_user(user_id, limit \\ 8) do
    AuditLog
    |> where([l], l.user_id == ^user_id)
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  One page of the audit trail, filtered and counted in the database.

  Returns `%{rows:, total:, page:, per_page:, total_pages:}`.

  Options: `:action` and `:resource_type` (exact, `""` for all), `:page`, `:per_page`.
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, 50) |> clamp(1, 200)

    query =
      AuditLog
      |> filter_equal(:action, Keyword.get(opts, :action))
      |> filter_equal(:resource_type, Keyword.get(opts, :resource_type))

    total = Repo.aggregate(query, :count, :id)
    total_pages = max(ceil(total / per_page), 1)
    page = opts |> Keyword.get(:page, 1) |> clamp(1, total_pages)

    rows =
      query
      |> order_by([l], desc: l.inserted_at, desc: l.id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()
      |> Repo.preload(:user)

    %{rows: rows, total: total, page: page, per_page: per_page, total_pages: total_pages}
  end

  defp filter_equal(query, _field, blank) when blank in [nil, ""], do: query

  defp filter_equal(query, field, value),
    do: where(query, [l], field(l, ^field) == ^value)

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum
end
