defmodule QuantumBilling.RateLimiter do
  @moduledoc """
  An in-memory sliding window rate limiter backed by ETS.

  Tracks attempt counts against configurable thresholds and windows (in seconds).
  Prunes expired entries periodically so memory usage remains bounded.
  """
  use GenServer

  @table :quantum_billing_rate_limiter
  @sweep_interval_ms :timer.seconds(60)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a hit for `key`.

  Returns `{:ok, remaining_attempts}` when within `limit`.
  Returns `{:error, :rate_limited, retry_after_seconds}` when limit is exceeded.
  """
  def hit(key, limit, window_seconds) do
    now = System.system_time(:second)
    reset_at = now + window_seconds

    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, 1, reset_at})
        {:ok, limit - 1}

      [{^key, count, stored_reset}] ->
        if now >= stored_reset do
          :ets.insert(@table, {key, 1, reset_at})
          {:ok, limit - 1}
        else
          new_count = count + 1

          if new_count > limit do
            retry_after = max(1, stored_reset - now)
            {:error, :rate_limited, retry_after}
          else
            :ets.insert(@table, {key, new_count, stored_reset})
            {:ok, limit - new_count}
          end
        end
    end
  end

  @doc """
  Checks if `key` is currently rate limited without incrementing the counter.
  """
  def limited?(key, limit) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, count, stored_reset}] when count >= limit and now < stored_reset ->
        true

      _ ->
        false
    end
  end

  @doc """
  Resets attempts for `key` (e.g. upon successful authentication).
  """
  def reset(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Clears all rate limit entries (primarily for testing).
  """
  def clear_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    prune_expired()
    schedule_sweep()
    {:noreply, state}
  end

  defp prune_expired do
    now = System.system_time(:second)
    ms = [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
    :ets.select_delete(@table, ms)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
