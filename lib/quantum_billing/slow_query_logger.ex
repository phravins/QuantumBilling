defmodule QuantumBilling.SlowQueryLogger do
  @moduledoc """
  Logs database queries that take longer than they should.

  Slow queries are how a system that is fine in testing becomes unusable in
  production, and they arrive gradually: a query that scans a table is
  imperceptible at a thousand rows and fatal at a million. Nothing surfaces
  that on its own — the page simply gets slower — so this watches Ecto's own
  telemetry and says which query, how long, and how much of it was spent
  waiting for a connection rather than running.

  Queue time is reported separately on purpose. A long queue time means the
  pool is exhausted, which is a different problem with a different fix from a
  query that is genuinely slow.

  The threshold is `:slow_query_ms` in application config (default 500ms); set
  it to `:infinity` to switch this off.
  """

  require Logger

  @handler_id :quantum_billing_slow_query_logger

  @doc """
  Attaches the handler. Called once at application start.
  """
  def attach do
    events = [[:quantum_billing, :repo, :query]]

    case :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      # Already attached: the application restarting inside a running VM.
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event([:quantum_billing, :repo, :query], measurements, metadata, _config) do
    threshold = threshold_ms()

    total =
      (measurements[:query_time] || 0) + (measurements[:queue_time] || 0) +
        (measurements[:decode_time] || 0)

    if threshold != :infinity and to_ms(total) >= threshold do
      Logger.warning(fn ->
        [
          "[slow query] ",
          format_ms(total),
          " (query ",
          format_ms(measurements[:query_time] || 0),
          ", queue ",
          format_ms(measurements[:queue_time] || 0),
          ", decode ",
          format_ms(measurements[:decode_time] || 0),
          ") source=",
          to_string(metadata[:source] || "-"),
          " ",
          String.slice(to_string(metadata[:query]), 0, 300)
        ]
      end)
    end

    :ok
  end

  defp threshold_ms, do: Application.get_env(:quantum_billing, :slow_query_ms, 500)

  defp to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  defp format_ms(native), do: "#{to_ms(native)}ms"
end
