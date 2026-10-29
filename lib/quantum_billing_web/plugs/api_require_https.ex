defmodule QuantumBillingWeb.Plugs.ApiRequireHttps do
  @moduledoc """
  Refuses API calls made over plain http, instead of redirecting them.

  The browser side of the application redirects http to https, and for a
  browser that is right. For an API client it is wrong: by the time a redirect
  is sent, the request — key and all — has already crossed the network in
  clear, and a client that follows the redirect then *works*, so nobody ever
  notices that every call is exposing the key. A refusal fails loudly, once,
  and gets the configuration fixed.

  `config/prod.exs` excludes `/api/v1` from `force_ssl`'s redirect so that
  this plug is what answers. `rewrite_on` still applies there, so behind a TLS
  proxy that sets `x-forwarded-proto` the scheme seen here is the real one.

  Off outside production, which runs over http.
  """

  alias QuantumBillingWeb.API.Error

  def init(opts), do: opts

  def call(conn, _opts) do
    if Application.get_env(:quantum_billing, :api_require_https, false) and conn.scheme != :https do
      Error.send(
        conn,
        403,
        :https_required,
        "The API is only available over https. This request was sent unencrypted, so " <>
          "treat the key it carried as exposed: revoke it and issue a new one."
      )
    else
      conn
    end
  end

  @doc """
  Whether a request is an API call, for `force_ssl`'s `:exclude`.

  Takes the conn because that is what `Plug.SSL`'s `{:conn, mfa}` exclusion
  passes.
  """
  def api_request?(%Plug.Conn{path_info: ["api", "v1" | _rest]}), do: true
  def api_request?(_conn), do: false
end
