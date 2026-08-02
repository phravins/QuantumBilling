defmodule QuantumBillingWeb.TransportErrorFilter do
  @moduledoc """
  Drops the OTP crash reports produced when a *client* aborts its TCP
  connection to the web server.

  ## What the reports look like

      [error] GenServer #PID<0.1582.0> terminating
      ** (stop) :econnaborted
      Process Label: {:thousand_island, :connection, {Bandit.DelegatingHandler, ...}}
      Last message: {:tcp_error, #Port<0.138>, :econnaborted}

  Nothing in this application failed. A browser closed a keep-alive connection
  abruptly — the report in question had already served ten requests on that
  connection. ThousandIsland treats a *clean* close (`:tcp_closed`) as a normal
  shutdown and says nothing, but a transport-level *error* takes this branch:

      def handle_info({msg, raw_socket, reason}, {socket, state})
          when msg in [:tcp_error, :ssl_error] do
        {:stop, reason, {socket, state}}
      end

  Stopping a GenServer with a reason that is neither `:normal` nor
  `{:shutdown, _}` is, to OTP, a crash — so it prints a full crash report for
  what is really just a peer hanging up rudely.

  ## Why not `silent_terminate_on_error`

  That is ThousandIsland's own option for quieting handler errors, and it is
  the obvious-looking fix, but it does not apply here. Its documentation is
  explicit: *"This only applies to errors returned via `{:error, reason, state}`
  responses"*. The `handle_info` clause above never consults it. Setting it
  would change nothing about these reports.

  ## What this filter will and will not hide

  Both conditions must hold before an event is dropped:

    * the process is a ThousandIsland *connection* process, identified by the
      label ThousandIsland sets on itself, and
    * the exit reason is a bare transport atom.

  A genuine crash inside a request carries a `{exception, stacktrace}` reason,
  not a bare atom, so it fails the second test and is logged as loudly as ever.
  Errors from any other process in the system fail the first.

  This runs in every environment deliberately. Aborted connections are not a
  development curiosity — in production, mobile clients, load-balancer health
  checks and scanners abort connections constantly, and a log full of crash
  reports for expected behaviour is how real errors get overlooked.
  """

  # Peer/transport failures. Deliberately excludes `:timeout`, which
  # ThousandIsland already reports as `{:shutdown, :read_timeout}` and which
  # could plausibly indicate something worth seeing.
  @transport_reasons [
    :econnaborted,
    :econnreset,
    :closed,
    :epipe,
    :etimedout,
    :ehostunreach,
    :enetunreach,
    :enotconn
  ]

  @doc """
  A `:logger` primary filter. Returns `:stop` to drop the event, `:ignore` to
  leave it for the handlers.
  """
  def filter(%{msg: {:report, report}}, _extra) when is_map(report) do
    case report do
      %{
        label: {:gen_server, :terminate},
        process_label: {:thousand_island, :connection, _},
        reason: reason
      }
      when reason in @transport_reasons ->
        :stop

      _other ->
        :ignore
    end
  end

  # Anything that is not a report is none of this filter's business. A logger
  # filter that raises takes the handler down with it, so the catch-all is not
  # optional.
  def filter(_event, _extra), do: :ignore

  @doc "The reasons treated as a peer hanging up rather than a fault."
  def transport_reasons, do: @transport_reasons
end
