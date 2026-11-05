import Config

# Fast password hashing for tests only.
config :pbkdf2_elixir, :rounds, 1

# Credentials are in runtime.exs. pool_size must exceed ExUnit's max_cases.
config :quantum_billing, QuantumBilling.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 4,
  # Waiting for a checkout is normal under test load.
  queue_target: 500,
  queue_interval: 2_000

# No server in tests; secret_key_base comes from runtime.exs.
config :quantum_billing, QuantumBillingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

config :quantum_billing, QuantumBilling.Mailer, adapter: Swoosh.Adapters.Test

config :swoosh, :api_client, false

config :logger, level: :warning

# Simulated payment links; production never fakes them.
config :quantum_billing, razorpay_sandbox: true

# The Migrator's advisory lock would deadlock on the sandbox's single connection.
config :quantum_billing, :tenant_migration_lock, false

# Calendar requests go to a stub instead of Google or a CalDAV server.
config :quantum_billing, :calendar_req_options, plug: {Req.Test, QuantumBilling.Calendars}

# In memory, so async tests sharing a key don't block; Postgres is tested separately.
config :quantum_billing, :rate_limiter, QuantumBilling.RateLimiter.ETS

# Outbound URLs are resolved by a fake, so tests never depend on real DNS.
config :quantum_billing, :url_guard_resolver, QuantumBilling.FakeDNS

config :quantum_billing, Oban, testing: :inline

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Stable query-param order for URL assertions.
config :phoenix,
  sort_verified_routes_query_params: true
