import Config

# Configure your database. Credentials live in config/runtime.exs.
config :quantum_billing, QuantumBilling.Repo,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# No caching; debugging, code reloading and asset watchers on.
config :quantum_billing, QuantumBillingWeb.Endpoint,
  # Loopback only; use {0, 0, 0, 0} to reach it from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  # secret_key_base is set in config/runtime.exs from SECRET_KEY_BASE.
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:quantum_billing, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:quantum_billing, ~w(--watch)]}
  ]

# Simulated payment links; production never fakes them.
config :quantum_billing, razorpay_sandbox: true

# LiveDashboard and the mailbox preview.
config :quantum_billing, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

# Deeper stacktraces; too costly for production.
config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Changing these needs `mix clean`.
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false
