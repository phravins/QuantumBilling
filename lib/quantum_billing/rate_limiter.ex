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

    # `update_counter/4` increments in place and inserts the default tuple if
    # the key is absent, both atomically. The previous read-then-write let two
    # requests read the same count and write the same increment, so a burst of
    # parallel attempts — which is precisely what a password-guessing script
    # sends — counted as one.
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0, reset_at})

    case :ets.lookup(@table, key) do
      [{^key, _count, stored_reset}] when stored_reset > now ->
        if count > limit do
          {:error, :rate_limited, max(1, stored_reset - now)}
        else
          {:ok, limit - count}
        end

      _expired_or_swept ->
        # The window closed. Start a new one at this hit rather than carrying
        # the old count into it.
        :ets.insert(@table, {key, 1, reset_at})
        {:ok, limit - 1}
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
