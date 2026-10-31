defmodule QuantumBilling.RateLimiter.Postgres do
  @moduledoc """
  The rate limiter's shared backend: one row per key in `public.rate_limits`.

  Each hit is a single `INSERT … ON CONFLICT DO UPDATE … RETURNING`, so the
  increment and the window check are one atomic statement in the database
  every server talks to. Two nodes counting the same key cannot both read the
  old count; a request spread across a cluster is counted once per request.

  Keys are stored as a SHA-256 of the key term, not the key: they are IP
  addresses and email addresses, and a table of who tried to sign in from
  where is not something to keep in clear.

  Expired rows are swept once a minute by the process this module runs.
  """
  use GenServer

  require Logger

  @behaviour QuantumBilling.RateLimiter

  alias QuantumBilling.Repo

  @sweep_interval_ms :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl QuantumBilling.RateLimiter
  def hit(key, limit, window_seconds) do
    # A window that has ended starts again at this hit; otherwise the count
    # goes up and the end of the window stays where it was.
    %{rows: [[count, retry_after]]} =
      Repo.query!(
        """
        INSERT INTO public.rate_limits AS r (key, count, reset_at)
        VALUES ($1, 1, now() + make_interval(secs => $2))
        ON CONFLICT (key) DO UPDATE SET
          count = CASE WHEN r.reset_at <= now() THEN 1 ELSE r.count + 1 END,
          reset_at = CASE WHEN r.reset_at <= now() THEN EXCLUDED.reset_at ELSE r.reset_at END
        RETURNING count, ceil(extract(epoch FROM r.reset_at - now()))::integer
        """,
        [digest(key), window_seconds]
      )

    if count > limit do
      {:error, :rate_limited, max(retry_after, 1)}
    else
      {:ok, limit - count}
    end
  end

  @impl QuantumBilling.RateLimiter
  def limited?(key, limit) do
    case Repo.query!(
           "SELECT count FROM public.rate_limits WHERE key = $1 AND reset_at > now()",
           [digest(key)]
         ) do
      %{rows: [[count]]} -> count >= limit
      %{rows: []} -> false
    end
  end

  @impl QuantumBilling.RateLimiter
  def reset(key) do
    Repo.query!("DELETE FROM public.rate_limits WHERE key = $1", [digest(key)])
    :ok
  end

  @impl QuantumBilling.RateLimiter
  def clear_all do
    Repo.query!("DELETE FROM public.rate_limits", [])
    :ok
  end

  @doc "Deletes expired rows. Returns how many."
  def sweep do
    %{num_rows: count} = Repo.query!("DELETE FROM public.rate_limits WHERE reset_at <= now()", [])
    count
  end

  defp digest(key), do: :crypto.hash(:sha256, :erlang.term_to_binary(key, [:deterministic]))

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    # A failed sweep only means the table is a minute bigger; it must never
    # take the limiter down with it.
    try do
      sweep()
    rescue
      error -> Logger.warning("[RateLimiter] sweep failed: #{Exception.message(error)}")
    end

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
