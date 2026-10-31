defmodule QuantumBillingWeb.Plugs.ApiResponseHeaders do
  @moduledoc """
  Headers for JSON responses, which skip the browser pipeline's.

    * `x-content-type-options: nosniff` — a browser that is somehow pointed at
      an API response renders it as the JSON it says it is, never as HTML.
    * `cache-control: no-store` — an API response is a business's data for one
      authenticated caller; no proxy or browser cache should keep a copy.
    * `content-security-policy: default-src 'none'; frame-ancestors 'none'` —
      a JSON body has nothing to load and nothing should frame it.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
  end
end
