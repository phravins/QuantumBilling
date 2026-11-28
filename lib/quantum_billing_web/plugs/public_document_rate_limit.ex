defmodule QuantumBillingWeb.Plugs.PublicDocumentRateLimit do
  @moduledoc """
  Limits requests to public documents and their PDFs per client address.

  The limit is the `:public_document_rate_limit` app setting, 30 a minute when
  unset. The test config raises it: every test request comes from 127.0.0.1,
  so with the real limit the whole suite would share one allowance.
  """

  import Plug.Conn

  alias QuantumBilling.RateLimiter
  alias QuantumBillingWeb.ClientIP

  @default_limit 30
  @window_seconds 60

  @doc "Requests allowed per client address in each window."
  def limit,
    do: Application.get_env(:quantum_billing, :public_document_rate_limit, @default_limit)

  def init(opts), do: opts

  def call(conn, _opts) do
    key = {:public_document, ClientIP.client_ip(conn)}

    case RateLimiter.hit(key, limit(), @window_seconds) do
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
