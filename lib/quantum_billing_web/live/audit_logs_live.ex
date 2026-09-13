defmodule QuantumBillingWeb.AuditLogsLive do
  @moduledoc """
  The audit trail: an immutable record of the actions the system took, and who
  asked for it.

  Paged by the database rather than read into the socket. The trail only grows,
  and filtering a fixed window of the newest rows in Elixir quietly hid every
  older match — a filter that misses the event being looked for is worse than
  no filter.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Audit
  alias QuantumBilling.Events

  @per_page 50

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe(Events.audit_logs_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Audit Logs")
     |> assign(:active_nav, :settings)
     |> assign(:section, :audit_logs)
     |> assign(:filter_action, "")
     |> assign(:page, 1)
     |> assign(:selected_log, nil)
     |> load_page()}
  end

  # Only the first page shows live arrivals: an event appearing at the top of
  # page four would push everything down by one and change what page five is.
  def handle_info({:audit_log_created, _log}, socket) do
    if socket.assigns.page == 1 do
      {:noreply, load_page(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("filter", %{"action" => action}, socket) do
    {:noreply,
     socket
     |> assign(:filter_action, action || "")
     |> assign(:page, 1)
     |> load_page()}
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page, ""} -> {:noreply, socket |> assign(:page, page) |> load_page()}
      _not_a_page -> {:noreply, socket}
    end
  end

  def handle_event("select_log", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} ->
        {:noreply, assign(socket, :selected_log, Enum.find(socket.assigns.logs, &(&1.id == id)))}

      _not_an_id ->
        {:noreply, socket}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :selected_log, nil)}
  end

  defp load_page(socket) do
    result =
      Audit.page(
        action: socket.assigns.filter_action,
        page: socket.assigns.page,
        per_page: @per_page
      )

    socket
    |> assign(:logs, result.rows)
    |> assign(:total, result.total)
    |> assign(:total_pages, result.total_pages)
    |> assign(:page, result.page)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      active_sub={@section}
    >
      <.header>
        Audit Trail &amp; Security Logs
        <:subtitle>
          Immutable record of all critical system actions, API events, and user modifications
        </:subtitle>

        <:actions>
          <div class="flex items-center gap-2">
            <select name="action" phx-change="filter" class="select select-bordered select-sm text-xs">
              <option value="">All Actions</option>
              <option value="generate_irn">E-Invoice (IRN)</option>
              <option value="generate_e_way_bill">E-Way Bill</option>
              <option value="generate_payment_link">Payment Link Created</option>
              <option value="payment_received">Payment Received</option>
            </select>
          </div>
        </:actions>
      </.header>

      <.card class="flex flex-1 flex-col p-4">
        <.empty_state
          :if={@logs == []}
          class="flex-1 justify-center"
          icon="hero-shield-check"
          title="No audit logs recorded yet"
          description="System events such as invoice issues, E-Invoice generation, and payment receipts will appear here."
        />

        <div :if={@logs != []} class="overflow-x-auto">
          <table class="table table-fixed w-full">
            <thead>
              <tr class={table_head_class()}>
                <th class="w-40">Timestamp</th>
                <th class="w-36">Action</th>
                <th class="w-28">Resource</th>
                <th class="w-36">Resource ID</th>
                <th class="w-40">User</th>
                <th class="w-28">IP Address</th>
                <th class="text-right w-20">Details</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={log <- @logs} id={"log-#{log.id}"} class={table_row_class()}>
                <td class="font-mono text-xs text-base-content/60">
                  {Calendar.strftime(log.inserted_at, "%Y-%m-%d %H:%M:%S")}
                </td>
                <td>
                  <span class="badge badge-outline text-xs font-semibold">{log.action}</span>
                </td>
                <td class="font-medium text-xs">{log.resource_type}</td>
                <td class="font-mono text-xs text-indigo-500">{log.resource_id || "-"}</td>
                <td class="text-xs truncate">
                  {if log.user, do: log.user.email, else: "System / Webhook"}
                </td>
                <td class="font-mono text-xs text-base-content/50">
                  {log.ip_address || "127.0.0.1"}
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    phx-click="select_log"
                    phx-value-id={log.id}
                    class="btn btn-xs btn-ghost text-xs"
                  >
                    View
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@total_pages > 1} class="mt-auto flex items-center justify-between gap-4 pt-4">
          <p class="text-xs text-base-content/45">
            {@total} recorded {if @total == 1, do: "event", else: "events"}
          </p>
          <.pagination current_page={@page} total_pages={@total_pages} />
        </div>
      </.card>

      <%!-- Audit Log Detail Modal --%>
      <div
        :if={@selected_log}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      >
        <div class="w-full max-w-lg rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl space-y-4">
          <div class="flex items-center justify-between border-b border-base-200 pb-3">
            <h3 class="text-base font-bold">Audit Event Detail</h3>
            <button
              type="button"
              phx-click="close_modal"
              class="text-base-content/50 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
          <div class="space-y-2 text-xs">
            <p><strong>Action:</strong> {@selected_log.action}</p>
            <p>
              <strong>Resource:</strong> {@selected_log.resource_type} (ID: {@selected_log.resource_id})
            </p>
            <p><strong>Timestamp:</strong> {to_string(@selected_log.inserted_at)}</p>
            <div>
              <label class="block font-semibold mb-1">Payload Details (JSON):</label>
              <pre class="p-3 bg-base-200 rounded-lg text-xs font-mono overflow-x-auto">{Jason.encode!(@selected_log.details, pretty: true)}</pre>
            </div>
          </div>
          <div class="flex justify-end pt-3">
            <button type="button" phx-click="close_modal" class="btn btn-sm btn-ghost">Close</button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
