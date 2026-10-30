defmodule QuantumBillingWeb.Plugs.CalendarFeedRateLimit do
  @moduledoc """
  Limits calendar feed requests per address.

  A calendar app polls every few minutes at most, so this leaves plenty of room
  for an office behind one address while making token guessing pointless.
  """
  import Plug.Conn

  alias QuantumBilling.RateLimiter
  alias QuantumBillingWeb.ClientIP

  @limit 60
  @window_seconds 60

  def init(opts), do: opts

  def call(conn, _opts) do
    case RateLimiter.hit({:calendar_feed, ClientIP.client_ip(conn)}, @limit, @window_seconds) do
      {:ok, _remaining} ->
        conn

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Too many requests")
        |> halt()
    end
  end
end
