defmodule QuantumBillingWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets the Content-Security-Policy for every page.

  Scripts: only the bundle and the one nonced inline theme script in the root
  layout, with a fresh nonce per response. Styles keep `'unsafe-inline'` for
  the invoice document's `<style>` tag and its validated accent property.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}'",
      "style-src 'self' 'unsafe-inline'",
      # data: for the inlined logo.
      "img-src 'self' data:",
      "font-src 'self' data:",
      connect_src(QuantumBillingWeb.Endpoint.config(:url)),
      "frame-ancestors 'none'",
      "frame-src 'none'",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'"
    ]
    |> Enum.join("; ")
  end

  @doc """
  Where the page may connect: itself and the LiveView socket. Over https that's
  this host's `wss:` only; dev and test keep a wider form.
  """
  def connect_src(url) do
    case {url[:scheme], url[:host]} do
      {"https", host} when is_binary(host) -> "connect-src 'self' wss://#{host}"
      _not_https -> "connect-src 'self' ws: wss:"
    end
  end
end
