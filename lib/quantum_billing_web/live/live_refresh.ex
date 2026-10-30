defmodule QuantumBillingWeb.LiveRefresh do
  @moduledoc """
  Throttles the reload a page does when a broadcast says its data changed.

  ## Why

  A page that re-reads on every `:invoice_changed` does one reload per write.
  One write is fine. The nightly recurring sweep is two hundred writes in a
  row, and the dashboard's reload is four aggregates over the whole invoice
  table — about half a second each on a million invoices — in every tab that
  has it open. That is minutes of database time to show a figure nobody can
  read before the next one replaces it.

  ## How

  The first change reloads at once, so a single edit looks exactly as it did
  before. It also opens a window of `window_ms/0`. Changes inside the window
  only mark the page stale; when it closes, a stale page reloads once and
  opens another window. A burst of any size costs one reload per window per
  tab, and the last reload always comes after the last change, so nothing is
  left showing old data.

  ## Use

      def handle_info({:invoice_changed, _invoice}, socket),
        do: {:noreply, LiveRefresh.changed(socket, &load_page/1)}

      def handle_info(:live_refresh_window_closed, socket),
        do: {:noreply, LiveRefresh.window_closed(socket, &load_page/1)}
  """

  import Phoenix.Component, only: [assign: 3]

  @window_ms 2_000

  @doc "How long a burst of changes is gathered before the next reload."
  def window_ms, do: @window_ms

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
