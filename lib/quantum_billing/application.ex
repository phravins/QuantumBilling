defmodule QuantumBilling.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    install_transport_error_filter()
    attach_job_logger()
    QuantumBilling.SlowQueryLogger.attach()

    children = [
      QuantumBillingWeb.Telemetry,
      QuantumBilling.Repo,
      {DNSCluster, query: Application.get_env(:quantum_billing, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: QuantumBilling.PubSub},
      QuantumBilling.RateLimiter,
      # Scheduled work — recurring billing, retention pruning — is Oban's,
      # through its Cron plugin. It used to be a GenServer with a 12-hour
      # timer, which ran on every node: two nodes billed every recurring
      # profile twice, and a restart reset the clock.
      {Oban, Application.fetch_env!(:quantum_billing, Oban)},
      QuantumBillingWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: QuantumBilling.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    QuantumBillingWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Silences the OTP crash reports emitted when a client aborts its TCP
  # connection. See `QuantumBillingWeb.TransportErrorFilter` for why these are
  # not application errors, and why ThousandIsland's own
  # `silent_terminate_on_error` option does not cover them.
  #
  # A primary filter, so it applies before any handler. `:already_exist` is
  # expected whenever the application is restarted in a running VM, as the code
  # reloader does in development.
  # Job failures are the one class of error nobody is watching a screen for:
  # they happen minutes after the click that caused them, in another process,
  # and without this they appear in the logs as a bare crash report with no
  # indication of which job it was. Oban's own handler prints the worker, the
  # arguments and the attempt.
  defp attach_job_logger do
    :ok = Oban.Telemetry.attach_default_logger(level: :info)
  rescue
    # Already attached — the application being restarted in a running VM, as
    # the code reloader does in development.
    ArgumentError -> :ok
  end

  defp install_transport_error_filter do
    :logger.add_primary_filter(
      :quantum_billing_transport_errors,
      {&QuantumBillingWeb.TransportErrorFilter.filter/2, []}
    )
    |> case do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
    end
  end
end
