defmodule QuantumBillingWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Declares where this application's pages may load things from.

  There was no policy at all before, which meant that any injected script
  anywhere — a stored one from an upload, a reflected one from a field that
  escaped badly — ran with nothing standing in its way.

  ## The nonce

  The root layout carries one inline `<script>`: it reads the saved theme and
  sets it before the first paint, so the page does not flash the wrong colours.
  That cannot move into the bundle without reintroducing the flash, and
  allowing it with `'unsafe-inline'` would allow every *other* inline script
  too, which is most of what a policy is for.

  So each response gets a random nonce, the layout stamps it on that one tag,
  and the policy trusts only that. The nonce is per response, so an injected
  script cannot carry a valid one — it would have to know a value generated
  after the page it is injecting into was requested.

  ## Why styles are not nonced

  `style-src` keeps `'unsafe-inline'`. The invoice document builds its
  stylesheet as an inline `<style>` tag, and the accent colour arrives as an
  inline custom property on an element. Both are deliberate (see
  `QuantumBillingWeb.InvoiceDoc.Renderer`), both are built from validated
  values — the accent is matched against `^#[0-9A-Fa-f]{6}$` — and CSS
  injection does not execute code. Nonce-ing the tag would still leave the
  style *attributes*, which need `'unsafe-inline'` regardless.
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
      # The LiveView socket; 'self' does not cover ws:.
      "connect-src 'self' ws: wss:",
      "frame-ancestors 'none'",
      "frame-src 'none'",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'"
    ]
    |> Enum.join("; ")
  end
end
