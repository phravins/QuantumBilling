defmodule QuantumBillingWeb.TransportErrorFilter do
  @moduledoc """
  Drops the OTP crash reports logged when a client aborts its TCP connection.

  ThousandIsland stops a connection on `:tcp_error`/`:ssl_error` with a bare
  reason such as `:econnaborted`, which OTP reports as a crash even though
  nothing failed. (`silent_terminate_on_error` doesn't cover this path.)

  An event is dropped only if it comes from a ThousandIsland connection process
  and its reason is a bare transport atom, so real request crashes still log.
  """

  # Excludes :timeout, which may be worth seeing.
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

  # A raising filter takes the handler down, so this catch-all is required.
  def filter(_event, _extra), do: :ignore

  @doc "The reasons treated as a peer hanging up rather than a fault."
  def transport_reasons, do: @transport_reasons
end
