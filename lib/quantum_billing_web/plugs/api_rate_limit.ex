defmodule QuantumBillingWeb.Plugs.ApiRateLimit do
  @moduledoc """
  Rate limits each API key, with writes far tighter than reads. Counters are
  shared across nodes (`RateLimiter` Postgres backend).
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
