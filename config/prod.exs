import Config

# Written by `mix assets.deploy`.
config :quantum_billing, QuantumBillingWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

# HTTPS and HSTS; must be set at compile time.
config :quantum_billing, QuantumBillingWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"],
      # ApiRequireHttps refuses http API calls instead of redirecting them.
      conn: {QuantumBillingWeb.Plugs.ApiRequireHttps, :api_request?, []}
    ]
  ]

config :quantum_billing, :api_require_https, true

# The session cookie is marked Secure; read at compile time by the endpoint.
config :quantum_billing, secure_session_cookie: true

config :swoosh, api_client: Swoosh.ApiClient.Req

config :swoosh, local: false

config :logger, level: :info

# Environment variables are read in config/runtime.exs.
