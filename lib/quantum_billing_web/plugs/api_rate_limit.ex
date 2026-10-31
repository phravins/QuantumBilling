defmodule QuantumBillingWeb.Plugs.ApiRateLimit do
  @moduledoc """
  Limits each API key's request rate.

  Per key, not per address: one integration should not be able to starve
  another, and a leaked key paging through every invoice is slowed to a crawl
  rather than emptying the table in a minute.

  Writes are limited far more tightly than reads. Every invoice created takes a
  number in a statutory series; a runaway loop doing that is worse than one
  reading.

  The counters are shared by every server (`QuantumBilling.RateLimiter`'s
  Postgres backend), so the limit holds however many nodes serve the API.
  """

  import Plug.Conn

  alias QuantumBilling.RateLimiter
  alias QuantumBillingWeb.API.Error

  @window_seconds 60
  @read_limit 600
  @write_limit 60

  def init(opts), do: opts

  def call(%{assigns: %{api_key: key}} = conn, _opts) do
    {kind, limit} =
      if conn.method in ~w(GET HEAD), do: {:read, @read_limit}, else: {:write, @write_limit}

    case RateLimiter.hit({:api, key.id, kind}, limit, @window_seconds) do
      {:ok, remaining} ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", to_string(max(remaining, 0)))

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_header("x-ratelimit-limit", to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> Error.send(429, :rate_limited, "Too many requests. Retry after #{retry_after}s.")
    end
  end
end
