defmodule QuantumBilling.RateLimiter.ETS do
  @moduledoc """
  The rate limiter's in-memory backend: a fixed window per key, in ETS.

  Counts are per node, so on several servers each one counts on its own and
  the effective limit is multiplied by the number of servers. That is why
  production uses `QuantumBilling.RateLimiter.Postgres`; this one serves the
  test suite, where sandboxed database transactions would make concurrent
  tests that share a key (one IP, say) wait on each other.

  Prunes expired entries periodically so memory usage remains bounded.
  """
  use GenServer

  @behaviour QuantumBilling.RateLimiter

  @table :quantum_billing_rate_limiter
  @sweep_interval_ms :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl QuantumBilling.RateLimiter
  def hit(key, limit, window_seconds) do
    now = System.system_time(:second)
    reset_at = now + window_seconds

    # Atomic increment, so parallel attempts are all counted.
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0, reset_at})

    case :ets.lookup(@table, key) do
      [{^key, _count, stored_reset}] when stored_reset > now ->
        if count > limit do
          {:error, :rate_limited, max(1, stored_reset - now)}
        else
          {:ok, limit - count}
        end

      _expired_or_swept ->
        :ets.insert(@table, {key, 1, reset_at})
        {:ok, limit - 1}
    end
  end

  @impl QuantumBilling.RateLimiter
  def limited?(key, limit) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, count, stored_reset}] when count >= limit and now < stored_reset ->
        true

      _ ->
        false
    end
  end

  @impl QuantumBilling.RateLimiter
  def reset(key) do
    :ets.delete(@table, key)
    :ok
  end

  @impl QuantumBilling.RateLimiter
  def clear_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl GenServer
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

  @impl GenServer
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
