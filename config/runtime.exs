import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Local secrets (.env)
#
# Elixir does not read .env files on its own, so this loads one if it is
# present. It runs here rather than in dev.exs/test.exs because those are
# evaluated before this file — which is why every secret below is configured
# here, not there.
#
# A real environment variable always wins over the file, so `.env` is a local
# convenience and never overrides what a server, CI job or container sets.
# In production there is no .env: the values come from the environment.
#
# Supported syntax: `KEY=value`, `export KEY=value`, `KEY="quoted value"`,
# blank lines, and `#` comments.
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

        # Real environment variables take precedence.
        if System.get_env(key) in [nil, ""] do
          System.put_env(key, value |> String.trim() |> unquote_value.())
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

      # MIX_TEST_PARTITION gives each CI partition its own database. It applies
      # to the test database only — appending it in dev would silently point
      # development at a different database whenever the variable is exported.
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

  # Not a real secret — it only signs cookies on a local machine, and a default
  # is needed so the app boots without setup. Override it via SECRET_KEY_BASE
  # for anything reachable by someone else. Generate one with `mix phx.gen.secret`.
  config :quantum_billing, QuantumBillingWeb.Endpoint,
    secret_key_base:
      System.get_env(
        "SECRET_KEY_BASE",
        "kR2vQ8xLmNfW5tYcJ7bPdA3hZgE6sU9nX1oI4jT0aVwK8yBrC5eM2pD7lF3qGnHu"
      )
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
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/quantum_billing_web/router\.ex$"E,
        ~r"lib/quantum_billing_web/(controllers|live|components)/.*\.(ex|heex)$"E
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
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

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

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :quantum_billing, QuantumBillingWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :quantum_billing, QuantumBillingWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :quantum_billing, QuantumBilling.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
