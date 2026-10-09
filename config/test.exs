import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database. Credentials live in config/runtime.exs.
# pool_size must exceed ExUnit's max_cases (schedulers_online() * 2), or sandbox
# checkouts time out under load.
config :quantum_billing, QuantumBilling.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 4,
  # A checkout that has to wait is normal here — the alternative is dropping it.
  queue_target: 500,
  queue_interval: 2_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
#
# secret_key_base is set in config/runtime.exs from SECRET_KEY_BASE.
config :quantum_billing, QuantumBillingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

# In test we don't send emails
config :quantum_billing, QuantumBilling.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Payment links are simulated here rather than calling Razorpay. In production
# a missing or rejected key is an error, not a fake link.
config :quantum_billing, razorpay_sandbox: true

# Configure Oban for inline testing
config :quantum_billing, Oban, testing: :inline

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
