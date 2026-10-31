defmodule QuantumBilling.RateLimiter do
  @moduledoc """
  Counts attempts per key in fixed windows, and says when a key is over its
  limit.

  The work is done by a backend chosen in configuration:

    * `QuantumBilling.RateLimiter.Postgres` — the default. One row per key in
      `public.rate_limits`, so every server counts against the same numbers: a
      password-guessing script spread across nodes is limited as one, and an
      API key's allowance does not grow with the cluster.
    * `QuantumBilling.RateLimiter.ETS` — in memory, per node. The test suite
      uses it; see that module for why.

      config :quantum_billing, :rate_limiter, QuantumBilling.RateLimiter.ETS
  """

  @doc """
  Registers a hit for `key`.

  `{:ok, remaining}` within `limit`, `{:error, :rate_limited, retry_after_seconds}`
  over it.
  """
  @callback hit(key :: term(), limit :: pos_integer(), window_seconds :: pos_integer()) ::
              {:ok, non_neg_integer()} | {:error, :rate_limited, pos_integer()}

  @doc "Whether `key` is at or over `limit` right now, without counting a hit."
  @callback limited?(key :: term(), limit :: pos_integer()) :: boolean()

  @doc "Forgets `key`, e.g. after a successful sign-in."
  @callback reset(key :: term()) :: :ok

  @doc "Forgets every key. For tests."
  @callback clear_all() :: :ok

  @doc false
  def child_spec(opts) do
    # The ETS table and the expiry sweep live in a process either way: the
    # Postgres backend's sweep keeps the table from growing.
    backend().child_spec(opts)
  end

  def hit(key, limit, window_seconds), do: backend().hit(key, limit, window_seconds)
  def limited?(key, limit), do: backend().limited?(key, limit)
  def reset(key), do: backend().reset(key)
  def clear_all, do: backend().clear_all()

  @doc "The backend in use."
  def backend,
    do: Application.get_env(:quantum_billing, :rate_limiter, QuantumBilling.RateLimiter.Postgres)
end
