defmodule QuantumBillingWeb.LiveRefresh do
  @moduledoc """
  Throttles page reloads triggered by change broadcasts.

  The first change reloads at once and opens a two-second window; later
  changes in it only mark the page stale, and it reloads once when the window
  closes. A burst costs one reload per window, and the last always follows the
  last change.

      def handle_info({:invoice_changed, _invoice}, socket),
        do: {:noreply, LiveRefresh.changed(socket, &load_page/1)}

      def handle_info(:live_refresh_window_closed, socket),
        do: {:noreply, LiveRefresh.window_closed(socket, &load_page/1)}
  """

  import Phoenix.Component, only: [assign: 3]

  @window_ms 2_000

  @doc "A change arrived: reload now, or mark the page stale until the window closes."
  def changed(socket, reload) when is_function(reload, 1) do
    case socket.assigns[:live_refresh] do
      state when state in [:waiting, :stale] -> assign(socket, :live_refresh, :stale)
      _idle -> reload_and_wait(socket, reload)
    end
  end

  @doc "The window closed: reload if anything changed during it, otherwise go idle."
  def window_closed(socket, reload) when is_function(reload, 1) do
    case socket.assigns[:live_refresh] do
      :stale -> reload_and_wait(socket, reload)
      _waiting_or_idle -> assign(socket, :live_refresh, :idle)
    end
  end

  defp reload_and_wait(socket, reload) do
    Process.send_after(self(), :live_refresh_window_closed, @window_ms)

    socket
    |> reload.()
    |> assign(:live_refresh, :waiting)
  end
end
