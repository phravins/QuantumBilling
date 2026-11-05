defmodule QuantumBilling.SlowQueryLogger do
  @moduledoc """
  Logs slow Ecto queries from telemetry, with queue time reported separately
  (a long queue means an exhausted pool, not a slow query).

  Threshold: `:slow_query_ms` (default 500); `:infinity` turns it off.
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
