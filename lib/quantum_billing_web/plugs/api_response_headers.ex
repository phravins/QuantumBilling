defmodule QuantumBillingWeb.Plugs.ApiResponseHeaders do
  @moduledoc """
  Security headers for JSON responses: `nosniff`, `cache-control: no-store`
  and `default-src 'none'; frame-ancestors 'none'`.
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
