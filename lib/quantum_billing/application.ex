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
      # Scheduled work runs through Oban's Cron plugin, so it runs once across nodes.
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

  # Oban's handler logs the worker, args and attempt for failed jobs.
  defp attach_job_logger do
    :ok = Oban.Telemetry.attach_default_logger(level: :info)
  rescue
    # Already attached after a code reload.
    ArgumentError -> :ok
  end

  # Silences crash reports from clients aborting their TCP connection;
  # see QuantumBillingWeb.TransportErrorFilter.
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
