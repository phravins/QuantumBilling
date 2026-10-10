import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Local secrets (.env)
#
# Loads .env if present. A real environment variable always wins over the file.
env_file = Path.expand("../.env", __DIR__)

if File.exists?(env_file) do
  unquote_value = fn value ->
    cond do
      String.starts_with?(value, ~s(")) and String.ends_with?(value, ~s(")) ->
        value |> String.slice(1..-2//1)

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.slice(1..-2//1)

      true ->
        value
    end
  end

  env_file
  |> File.read!()
  |> String.split(~r/\r?\n/)
  |> Enum.each(fn line ->
    line = line |> String.trim() |> String.replace_prefix("export ", "")

    case {line, String.split(line, "=", parts: 2)} do
      {"", _} ->
        :ok

      {"#" <> _, _} ->
        :ok

      {_, [key, value]} ->
        key = String.trim(key)
        value = value |> String.trim() |> unquote_value.()

        # Skip blanks: "" is truthy, so `PHX_SERVER=` would start the server during `mix test`.
        if value != "" and System.get_env(key) in [nil, ""] do
          System.put_env(key, value)
        end

      {_, _} ->
        :ok
    end
  end)
end

# Database connection, shared by dev and test. Defaults keep a fresh clone and
# CI working with no .env at all; set the variables to point somewhere else.
if config_env() in [:dev, :test] do
  database =
    case config_env() do
      :dev ->
        System.get_env("DB_NAME", "quantum_billing_dev")

      # Test database only; appending it in dev would silently switch databases.
      :test ->
        System.get_env("DB_NAME_TEST", "quantum_billing_test") <>
          (System.get_env("MIX_TEST_PARTITION") || "")
    end

  config :quantum_billing, QuantumBilling.Repo,
    username: System.get_env("DB_USERNAME", "postgres"),
    password: System.get_env("DB_PASSWORD", "postgres"),
    hostname: System.get_env("DB_HOSTNAME", "localhost"),
    port: String.to_integer(System.get_env("DB_PORT", "5432")),
    database: database

  # A local-only default so the app boots; override with SECRET_KEY_BASE
  # (`mix phx.gen.secret`).
  config :quantum_billing, QuantumBillingWeb.Endpoint,
    secret_key_base:
      System.get_env(
        "SECRET_KEY_BASE",
        "kR2vQ8xLmNfW5tYcJ7bPdA3hZgE6sU9nX1oI4jT0aVwK8yBrC5eM2pD7lF3qGnHu"
      )

  # Encrypts TOTP secrets at rest; override with TOTP_ENCRYPTION_KEY. Changing it
  # invalidates every 2FA enrolment.
  config :quantum_billing,
    totp_encryption_key:
      System.get_env(
        "TOTP_ENCRYPTION_KEY",
        "dev-only-totp-key-Xq7Pm2Lw9Rt4Yv6Bn8Kc3Fh5Jd1Sa0Zg"
      ),
    # Encrypts stored credentials (SMTP, Razorpay, IRP, webhook). Separate from the
    # TOTP key so rotating one leaves 2FA alone.
    secrets_encryption_key:
      System.get_env(
        "SECRETS_ENCRYPTION_KEY",
        "dev-only-secrets-key-Bv4Nz8Qr1Tm6Wk3Hy7Lc5Pd2Jf9Xs0A"
      )
end

# See QuantumBilling.SlowQueryLogger.
config :quantum_billing,
  slow_query_ms: String.to_integer(System.get_env("SLOW_QUERY_MS") || "500")

# Disable only for a self-signed relay on a trusted network.
config :quantum_billing,
  smtp_tls_verify: System.get_env("SMTP_TLS_VERIFY") not in ["false", "0"]

# Trusted proxies (addresses or CIDRs) for x-forwarded-for; empty ignores the
# header. See QuantumBillingWeb.ClientIP.
config :quantum_billing,
  trusted_proxies:
    (System.get_env("TRUSTED_PROXIES") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

# Never in tests: it would replace the test adapter and send real mail.
if (smtp_host = System.get_env("SMTP_HOST")) && config_env() != :test do
  smtp_port = String.to_integer(System.get_env("SMTP_PORT", "587"))
  implicit_tls? = System.get_env("SMTP_SSL") in ["true", "1"] or smtp_port == 465

  # Verified TLS, as for the per-organisation relay (see QuantumBilling.Mail).
  smtp_tls_options =
    if System.get_env("SMTP_TLS_VERIFY") in ["false", "0"] do
      [verify: :verify_none, versions: [:"tlsv1.2", :"tlsv1.3"], middlebox_comp_mode: false]
    else
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        server_name_indication: to_charlist(smtp_host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        # The same two allowances as the per-organisation relay; see
        # `QuantumBilling.Mail.verify_cert/3`.
        verify_fun: {&QuantumBilling.Mail.verify_cert/3, nil},
        versions: [:"tlsv1.2", :"tlsv1.3"],
        middlebox_comp_mode: false
      ]
    end

  config :quantum_billing, QuantumBilling.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_host,
    port: smtp_port,
    username: System.get_env("SMTP_USERNAME"),
    password: System.get_env("SMTP_PASSWORD"),
    ssl: implicit_tls?,
    tls: if(implicit_tls?, do: :never, else: :always),
    tls_options: smtp_tls_options,
    sockopts: if(implicit_tls?, do: smtp_tls_options, else: []),
    auth: if(System.get_env("SMTP_USERNAME"), do: :always, else: :never),
    no_mx_lookups: true,
    retries: 0
end

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/quantum_billing start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :quantum_billing, QuantumBillingWeb.Endpoint, server: true
end

config :quantum_billing, QuantumBillingWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :quantum_billing, QuantumBillingWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/quantum_billing_web/router\.ex$",
        ~r"lib/quantum_billing_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :quantum_billing, QuantumBilling.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6,
    # Fail fast when the pool is overloaded rather than queueing for ever.
    queue_target: String.to_integer(System.get_env("DB_QUEUE_TARGET_MS") || "150"),
    queue_interval: String.to_integer(System.get_env("DB_QUEUE_INTERVAL_MS") || "1000"),
    # A single statement that runs longer than this is not serving a page.
    # Reports that legitimately take longer pass their own timeout.
    timeout: String.to_integer(System.get_env("DB_TIMEOUT_MS") || "15000"),
    # Postgres closes idle connections and load balancers drop them; this
    # notices before a request does.
    idle_interval: 15_000

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Required at boot: without it every stored TOTP secret is undecryptable.
  totp_encryption_key =
    System.get_env("TOTP_ENCRYPTION_KEY") ||
      raise """
      environment variable TOTP_ENCRYPTION_KEY is missing.

      It encrypts two-factor secrets at rest. Generate one by calling:
      mix phx.gen.secret

      Changing it later invalidates every existing 2FA enrolment.
      """

  config :quantum_billing, totp_encryption_key: totp_encryption_key

  # Required at boot: the stored credentials are encrypted with it.
  secrets_encryption_key =
    System.get_env("SECRETS_ENCRYPTION_KEY") ||
      raise """
      environment variable SECRETS_ENCRYPTION_KEY is missing.

      It encrypts stored integration credentials (SMTP password, Razorpay key
      secret, IRP password, webhook secret) at rest. Generate one by calling:

      mix phx.gen.secret

      Changing it later makes the stored credentials unreadable and they have
      to be entered again.
      """

  config :quantum_billing, secrets_encryption_key: secrets_encryption_key

  host = System.get_env("PHX_HOST") || "example.com"

  config :quantum_billing, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :quantum_billing, QuantumBillingWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
