defmodule QuantumBilling.Application do
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
      QuantumBilling.RateLimiter,
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
