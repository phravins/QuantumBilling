defmodule QuantumBilling.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    install_transport_error_filter()

    children = [
      QuantumBillingWeb.Telemetry,
      QuantumBilling.Repo,
      {DNSCluster, query: Application.get_env(:quantum_billing, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: QuantumBilling.PubSub},
      # Start a worker by calling: QuantumBilling.Worker.start_link(arg)
      # {QuantumBilling.Worker, arg},
      # Start to serve requests, typically the last entry
      QuantumBillingWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: QuantumBilling.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
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
