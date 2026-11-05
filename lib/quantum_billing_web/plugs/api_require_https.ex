defmodule QuantumBillingWeb.Plugs.ApiRequireHttps do
  @moduledoc """
  Refuses plain-http API calls instead of redirecting them: by the time a
  redirect is sent, the key has already crossed in clear.

  `config/prod.exs` excludes `/api/v1` from `force_ssl` so this plug answers.
  Off outside production.
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

  @doc "Whether a request is an API call, for `force_ssl`'s `:exclude` (`{:conn, mfa}`)."
  def api_request?(%Plug.Conn{path_info: ["api", "v1" | _rest]}), do: true
  def api_request?(_conn), do: false
end
