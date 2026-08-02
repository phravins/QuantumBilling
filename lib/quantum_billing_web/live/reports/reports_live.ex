defmodule QuantumBillingWeb.ReportsLive do
  @moduledoc """
  The Reports page: headline totals, an invoice-value trend, a status
  breakdown, a tax summary by tax type and the top clients — all driven by one
  set of filters.

  `mount/3` loads the dataset once and `handle_event/3` only ever updates raw
  filter state; `render/1` re-derives every panel from
  `QuantumBilling.Reports.filter/2` on each pass, so there is a single source of
  truth and no chance of two panels disagreeing.

  Charts here carry colour. That is deliberate and confined to them — every
  other element uses the monochrome classes shared with the rest of the app.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.DashboardComponents, only: [stat_card: 1, donut_chart: 1]
  import QuantumBillingWeb.ReportsComponents

  alias QuantumBilling.Invoices
  alias QuantumBilling.Reports

  def mount(_params, _session, socket) do
    if connected?(socket), do: Invoices.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Reports")
     |> assign(:active_nav, :reports)
     |> assign(:invoices, Reports.invoices())
     |> assign(:filters, Reports.default_filters())}
  end

  # Only the underlying set is replaced. The active filters stay put, so a
  # report someone is reading does not reset itself when an invoice changes.
  def handle_info({:invoice_changed, _invoice}, socket) do
    {:noreply, assign(socket, :invoices, Reports.invoices())}
  end

  def handle_event("filter", params, socket) do
    filters =
      socket.assigns.filters
      |> put_filter(params, "report_type", :report_type)
      |> put_filter(params, "client", :client)
      |> put_filter(params, "status", :status)
      |> put_filter(params, "gstin", :gstin)

    {:noreply, assign(socket, :filters, filters)}
  end

  # The Apply button submits the same form; the change handler has already
  # applied everything, so this only needs to acknowledge it.
  def handle_event("apply_filters", params, socket) do
    handle_event("filter", params, socket)
  end

  def handle_event("reset_filters", _params, socket) do
    {:noreply, assign(socket, :filters, Reports.default_filters())}
  end

  def handle_event("set_range", %{"range" => range}, socket) do
    {:noreply, assign(socket, :filters, Map.put(socket.assigns.filters, :date_range, range))}
  end

  defp put_filter(filters, params, key, field) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(filters, field, value)
      :error -> filters
    end
  end

  def render(assigns) do
    filtered = Reports.filter(assigns.invoices, assigns.filters)

    assigns =
      assign(assigns,
        summary: Reports.summary(filtered),
        trend: Reports.monthly_trend(filtered),
        breakdown: Reports.status_breakdown(filtered),
        tax_rows: Reports.tax_summary(filtered),
        top_clients: Reports.top_clients(filtered),
        total_count: length(filtered)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        Reports
        <:subtitle>Analyze your business data and GST performance</:subtitle>
        <:actions>
          <div class="flex items-center gap-2">
            <.link
              href={~p"/reports/export?#{export_params(@filters)}"}
              class={secondary_button_class()}
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Export Report
            </.link>

            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class={secondary_button_class()}>
                <.icon name="hero-calendar-days" class="size-4" />
                {Reports.range_label(@filters.date_range)}
                <.icon name="hero-chevron-down" class="size-4" />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu z-10 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
              >
                <li :for={range <- Reports.date_ranges()}>
                  <a phx-click="set_range" phx-value-range={range}>{range}</a>
                </li>
              </ul>
            </div>
          </div>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_card
          label="Total Invoices"
          value={Integer.to_string(@summary.count)}
          icon="hero-document-text"
          delta_text={delta_text(@summary.count_delta)}
          delta_class={delta_class(@summary.count_delta)}
          delta_icon={delta_icon(@summary.count_delta)}
        />
        <.stat_card
          label="Total Taxable Value"
          value={rupees(@summary.taxable_value)}
          icon="hero-currency-rupee"
          delta_text={delta_text(@summary.taxable_delta)}
          delta_class={delta_class(@summary.taxable_delta)}
          delta_icon={delta_icon(@summary.taxable_delta)}
        />
        <.stat_card
          label="Total Tax Amount"
          value={rupees(@summary.tax_amount)}
          icon="hero-receipt-percent"
          delta_text={delta_text(@summary.tax_delta)}
          delta_class={delta_class(@summary.tax_delta)}
          delta_icon={delta_icon(@summary.tax_delta)}
        />
        <.stat_card
          label="Total Invoice Value"
          value={rupees(@summary.invoice_value)}
          icon="hero-banknotes"
          delta_text={delta_text(@summary.invoice_delta)}
          delta_class={delta_class(@summary.invoice_delta)}
          delta_icon={delta_icon(@summary.invoice_delta)}
        />
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-12">
        <.card class="lg:col-span-5">
          <div class="mb-4 flex items-center justify-between gap-4">
            <h2 class="text-sm font-semibold tracking-tight">Invoice Value Trend</h2>
            <span class="text-xs text-base-content/45">{@filters.date_range}</span>
          </div>
          <.line_chart points={@trend} />
        </.card>

        <.card class="lg:col-span-4">
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Invoices by Status</h2>
          <.donut_chart
            :if={@breakdown != []}
            segments={@breakdown}
            total={@total_count}
            palette={:color}
            show_percent
          />
          <p :if={@breakdown == []} class="py-12 text-center text-sm text-base-content/45">
            No invoices match these filters.
          </p>
        </.card>

        <.card class="lg:col-span-3">
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Filters</h2>

          <form
            id="reports-filters"
            phx-change="filter"
            phx-submit="apply_filters"
            class="space-y-3"
          >
            <.filter_field
              label="Report Type"
              name="report_type"
              value={@filters.report_type}
              options={Reports.report_types()}
            />
            <.filter_field
              label="Client"
              name="client"
              value={@filters.client}
              options={Reports.client_names()}
            />
            <.filter_field
              label="Status"
              name="status"
              value={@filters.status}
              options={Reports.statuses()}
            />
            <.filter_field
              label="GSTIN"
              name="gstin"
              type="text"
              value={@filters.gstin}
              placeholder="Enter GSTIN"
            />

            <button type="submit" class={[action_button_class(), "mt-1 w-full justify-center"]}>
              Apply Filters
            </button>
          </form>

          <.reset_link />
        </.card>
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-12">
        <.card class="lg:col-span-8">
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Tax Summary (by Tax Type)</h2>

          <div class="overflow-x-auto">
            <table class="w-full">
              <thead>
                <tr class={table_head_class()}>
                  <th class="pr-4 text-left font-medium">Tax Type</th>
                  <th class="pr-4 text-right font-medium">Taxable Value (₹)</th>
                  <th class="pr-4 text-right font-medium">CGST (₹)</th>
                  <th class="pr-4 text-right font-medium">SGST (₹)</th>
                  <th class="pr-4 text-right font-medium">IGST (₹)</th>
                  <th class="text-right font-medium">Total Tax (₹)</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @tax_rows}
                  class={[table_row_class(), row.total? && "font-semibold [&>td]:underline"]}
                >
                  <td class="py-2.5 pr-4">{row.label}</td>
                  <td class="py-2.5 pr-4 text-right">{rupees(row.taxable_value, decimals: 2)}</td>
                  <td class="py-2.5 pr-4 text-right"><.tax_cell amount={row.cgst} /></td>
                  <td class="py-2.5 pr-4 text-right"><.tax_cell amount={row.sgst} /></td>
                  <td class="py-2.5 pr-4 text-right"><.tax_cell amount={row.igst} /></td>
                  <td class="py-2.5 text-right">{rupees(row.total_tax, decimals: 2)}</td>
                </tr>
                <tr :if={@tax_rows == []}>
                  <td colspan="6" class="py-8 text-center text-sm text-base-content/45">
                    No invoices match these filters.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card class="lg:col-span-4">
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Top Clients by Invoice Value</h2>

          <ul class="space-y-3.5">
            <.top_client_row
              :for={{client, index} <- Enum.with_index(@top_clients, 1)}
              rank={index}
              name={client.client}
              value={rupees(client.value)}
            />
          </ul>

          <p :if={@top_clients == []} class="py-8 text-center text-sm text-base-content/45">
            No invoices match these filters.
          </p>

          <.link
            navigate={~p"/clients"}
            class="mt-4 flex items-center justify-center gap-1.5 text-sm font-medium text-base-content hover:underline"
          >
            View all clients <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp export_params(filters) do
    [
      date_range: filters.date_range,
      report_type: filters.report_type,
      client: filters.client,
      status: filters.status,
      gstin: filters.gstin
    ]
  end

  defp delta_text(nil), do: nil

  defp delta_text(percent) do
    sign = if percent >= 0, do: "+", else: ""
    "#{sign}#{:erlang.float_to_binary(percent, decimals: 1)}% from last month"
  end

  defp delta_class(percent) when is_number(percent) and percent < 0, do: "text-error"
  defp delta_class(_percent), do: "text-success"

  defp delta_icon(nil), do: nil
  defp delta_icon(percent) when percent < 0, do: "hero-arrow-trending-down"
  defp delta_icon(_percent), do: "hero-arrow-trending-up"
end
