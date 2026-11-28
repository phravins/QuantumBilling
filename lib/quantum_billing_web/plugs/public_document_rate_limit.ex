defmodule QuantumBillingWeb.Plugs.PublicDocumentRateLimit do
  @moduledoc "Limits requests to public documents and their PDFs per client address."

  import Plug.Conn

  alias QuantumBilling.RateLimiter
  alias QuantumBillingWeb.ClientIP

  @limit 30
  @window_seconds 60

  def init(opts), do: opts

  def call(conn, _opts) do
    key = {:public_document, ClientIP.client_ip(conn)}

    case RateLimiter.hit(key, @limit, @window_seconds) do
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
