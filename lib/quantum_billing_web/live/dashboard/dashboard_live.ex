defmodule QuantumBillingWeb.DashboardLive do
  @moduledoc """
  The one overview of the business: headline stats, the six-month tax trend,
  the status breakdown, this year's tax summary and top clients, the
  compliance calendar, and the CSV exports.

  It replaced a separate Reports page that repeated the same cards, trend and
  status donut. The two Reports panels that said something new — tax by type
  and top clients — live here, read through `QuantumBilling.Reports` for the
  current year, and the export links point at the same `/reports/export`
  download.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.DashboardComponents

  alias QuantumBilling.Compliance
  alias QuantumBilling.Invoices
  alias QuantumBilling.Reports
  alias QuantumBillingWeb.LiveRefresh

  def mount(_params, _session, socket) do
    if connected?(socket), do: Invoices.subscribe()

    {:ok, assign_dashboard(socket)}
  end

  # Throttled: a burst of writes, like the nightly recurring sweep, reloads once per window.
  def handle_info({:invoice_changed, _invoice}, socket) do
    {:noreply, LiveRefresh.changed(socket, &assign_dashboard/1)}
  end

  def handle_info(:live_refresh_window_closed, socket) do
    {:noreply, LiveRefresh.window_closed(socket, &assign_dashboard/1)}
  end

  defp assign_dashboard(socket) do
    today = Date.utc_today()
    totals = Invoices.totals()
    month = Invoices.month_totals(today)
    status_counts = Invoices.status_counts()
    chart_months = billed_months(Invoices.monthly_tax_split(6, today))
    obligations = Compliance.obligations(today)
    # This year, as the export links download it.
    year = Reports.default_filters()
    tax_rows = Reports.tax_rows(year)

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:active_nav, :dashboard)
    |> assign(:stats, stats(totals, month, obligations))
    |> assign(:chart_months, chart_months)
    |> assign(:chart_series, chart_series(chart_months))
    |> assign(:chart_labels, Enum.map(chart_months, & &1.label))
    |> assign(:chart_max, chart_max(chart_months))
    |> assign(:chart_axis, chart_axis(chart_max(chart_months)))
    |> assign(:donut_segments, donut_segments(status_counts))
    |> assign(:donut_total, totals.count)
    |> assign(:tax_rows, tax_rows)
    # Only the totals row means nothing was billed.
    |> assign(:has_tax_rows, Enum.any?(tax_rows, &(not &1.total?)))
    |> assign(:top_clients, Reports.top_client_totals(year))
    |> assign(:period_label, Reports.range_label(year.date_range, today))
    |> assign(:compliance_items, compliance_items(obligations, today))
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        Dashboard
        <:subtitle>Overview of your GST invoicing and compliance</:subtitle>

        <:actions>
          <div id="dashboard-export" class="dropdown dropdown-end">
            <div tabindex="0" role="button" class={secondary_button_class()}>
              <.icon name="hero-arrow-down-tray" class="size-4" /> Export
              <.icon name="hero-chevron-down" class="size-4" />
            </div>

            <ul
              tabindex="0"
              class="dropdown-content menu z-10 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
            >
              <li>
                <.link
                  id="export-tax-summary"
                  href={~p"/reports/export?#{[date_range: "This Year"]}"}
                >
                  GST tax summary – this year (CSV)
                </.link>
              </li>
              <li>
                <.link
                  id="export-sales-register"
                  href={
                    ~p"/reports/export?#{[date_range: "This Year", report_type: "Sales Register"]}"
                  }
                >
                  Sales register – this year (CSV)
                </.link>
              </li>
            </ul>
          </div>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_card
          :for={stat <- @stats}
          label={stat.label}
          value={stat.value}
          icon={stat.icon}
          tone={stat.tone}
          delta_text={stat.delta_text}
          delta_class={stat.delta_class}
          delta_icon={stat.delta_icon}
        />
      </div>

      <div class="mt-3 grid grid-cols-1 gap-3 lg:grid-cols-3">
        <.card class="flex flex-col lg:col-span-2">
          <div class="mb-3 flex items-center justify-between">
            <h2 class="text-sm font-semibold tracking-tight">GST Invoices - Last 6 Months</h2>

            <div class="flex items-center gap-3 text-xs text-base-content/60">
              <span class="flex items-center gap-1.5">
                <span class="size-2 rounded-full bg-blue-500" /> CGST + SGST
              </span>

              <span class="flex items-center gap-1.5">
                <span class="size-2 rounded-full bg-violet-400" /> IGST
              </span>
            </div>
          </div>
          <.area_chart
            :if={@chart_months != []}
            id="dashboard-tax-trend"
            series={@chart_series}
            labels={@chart_labels}
            max={@chart_max}
            axis_labels={@chart_axis}
            format={&money_axis_label/1}
            class="min-h-0 flex-1"
          />
          <.empty_state
            :if={@chart_months == []}
            class="flex-1 justify-center"
            icon="hero-chart-bar"
            title="No invoice data yet"
            description="This chart fills in once you have invoices to report on."
          />
        </.card>

        <.card>
          <h2 class="mb-2.5 text-sm font-semibold tracking-tight">Invoices by Status</h2>

          <.donut_chart
            :if={@donut_segments != []}
            segments={@donut_segments}
            total={@donut_total}
            palette={:color}
          />
          <.empty_state
            :if={@donut_segments == []}
            icon="hero-chart-pie"
            title="No invoices yet"
            description="Status breakdown appears once invoices exist."
          />
        </.card>
      </div>

      <%!-- grow, not flex-1: flex-1 zeroes the basis and would let a tall table shrink. --%>
      <div class="mt-3 grid grow grid-cols-1 gap-3 lg:grid-cols-12">
        <.card id="dashboard-tax-summary" class="flex flex-col lg:col-span-6">
          <div class="mb-2.5 flex items-center justify-between gap-3">
            <h2 class="text-sm font-semibold tracking-tight">Tax Summary (by Tax Type)</h2>
            <span class="text-xs text-base-content/45">{@period_label}</span>
          </div>

          <div :if={@has_tax_rows} class="overflow-x-auto">
            <table class="w-full">
              <thead>
                <tr class={table_head_class()}>
                  <th class="pr-4 text-left">Tax Type</th>
                  <th class="pr-4">Taxable Value (₹)</th>
                  <th class="pr-4">CGST (₹)</th>
                  <th class="pr-4">SGST (₹)</th>
                  <th class="pr-4">IGST (₹)</th>
                  <th>Total Tax (₹)</th>
                </tr>
              </thead>

              <tbody>
                <tr
                  :for={row <- @tax_rows}
                  class={[table_row_class(), row.total? && "font-semibold [&>td]:underline"]}
                >
                  <td class="py-2.5 pr-4">{row.label}</td>
                  <td class="py-2.5 pr-4">{rupees(row.taxable_value, decimals: 2)}</td>
                  <td class="py-2.5 pr-4"><.tax_cell amount={row.cgst} /></td>
                  <td class="py-2.5 pr-4"><.tax_cell amount={row.sgst} /></td>
                  <td class="py-2.5 pr-4"><.tax_cell amount={row.igst} /></td>
                  <td class="py-2.5">{rupees(row.total_tax, decimals: 2)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <.empty_state
            :if={!@has_tax_rows}
            class="flex-1 justify-center"
            icon="hero-receipt-percent"
            title="No tax to summarise yet"
            description="Tax by type appears once this year has invoices."
          />
        </.card>

        <.card id="dashboard-top-clients" class="flex flex-col lg:col-span-3">
          <div class="mb-2.5 flex items-center justify-between gap-3">
            <h2 class="text-sm font-semibold tracking-tight">Top Clients</h2>
            <span class="text-xs text-base-content/45">{@period_label}</span>
          </div>

          <ul :if={@top_clients != []} class="space-y-3.5">
            <.top_client_row
              :for={{client, index} <- Enum.with_index(@top_clients, 1)}
              rank={index}
              name={client.client}
              value={rupees(client.value)}
            />
          </ul>

          <.empty_state
            :if={@top_clients == []}
            class="flex-1 justify-center"
            icon="hero-users"
            title="No clients billed yet"
            description="Your highest-billed clients this year appear here."
          />
          <.link
            navigate={~p"/clients"}
            class="mt-auto block pt-4 text-sm font-medium text-base-content hover:underline"
          >
            View all clients &rarr;
          </.link>
        </.card>

        <.card class="flex flex-col lg:col-span-3">
          <h2 class="mb-2.5 text-sm font-semibold tracking-tight">Compliance Calendar</h2>

          <ul :if={@compliance_items != []} class="space-y-3">
            <li :for={item <- @compliance_items} class="flex items-center gap-3">
              <.compliance_date_badge month={item.month} day={item.day} tone={item.tone} />
              <div>
                <p class="text-sm font-medium">{item.title}</p>

                <p class={["text-xs", item.due_class]}>{item.due_text}</p>
              </div>
            </li>
          </ul>

          <.empty_state
            :if={@compliance_items == []}
            icon="hero-calendar-days"
            title="No upcoming due dates"
            description="GST filing deadlines will appear here."
          />
          <.link
            navigate={~p"/compliance"}
            class="mt-auto block pt-4 text-sm font-medium text-base-content hover:underline"
          >
            View all due dates &rarr;
          </.link>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp stats(totals, month, obligations) do
    pending_returns =
      Enum.count(obligations, &(&1.status in ["Pending", "Overdue"] and &1.category == :returns))

    overdue_returns = Enum.count(obligations, &(&1.status == "Overdue"))

    [
      %{
        label: "Invoices Issued",
        value: Integer.to_string(totals.count),
        icon: "hero-document-text",
        tone: :info,
        delta_text: "#{month.count} this month",
        delta_class: "text-base-content/45",
        delta_icon: nil
      },
      %{
        label: "Current Month Tax Liability",
        value: rupees(month.tax),
        icon: "hero-currency-rupee",
        tone: :accent,
        delta_text: "on #{rupees(month.taxable_value)} taxable",
        delta_class: "text-base-content/45",
        delta_icon: nil
      },
      %{
        label: "Outstanding Receivables",
        value: rupees(totals.outstanding),
        icon: "hero-banknotes",
        tone: :warning,
        delta_text: "#{totals.paid_count} paid in full",
        delta_class: "text-base-content/45",
        delta_icon: nil
      },
      %{
        label: "Pending GST Returns",
        value: Integer.to_string(pending_returns),
        icon: "hero-calendar-days",
        tone: if(overdue_returns > 0, do: :danger, else: :success),
        delta_text:
          if(overdue_returns > 0, do: "#{overdue_returns} overdue", else: "None overdue"),
        delta_class: if(overdue_returns > 0, do: "text-error", else: "text-base-content/45"),
        delta_icon: if(overdue_returns > 0, do: "hero-exclamation-triangle", else: nil)
      }
    ]
  end

  # All zeros is an empty state, not a chart.
  defp billed_months(months) do
    if Enum.all?(months, &(&1.cgst_sgst == 0 and &1.igst == 0)), do: [], else: months
  end

  defp chart_series(months) do
    [
      %{label: "CGST + SGST", tone: :blue, values: Enum.map(months, & &1.cgst_sgst)},
      %{label: "IGST", tone: :violet, values: Enum.map(months, & &1.igst)}
    ]
  end

  defp chart_axis(max) do
    Enum.map(4..0//-1, fn i -> money_axis_label(div(max, 4) * i) end)
  end

  # Rounded up so gridlines land on round numbers.
  defp chart_max(months) do
    tallest =
      months
      |> Enum.flat_map(&[&1.cgst_sgst, &1.igst])
      |> Enum.max(fn -> 0 end)

    if tallest <= 0 do
      1_000
    else
      step = tallest |> div(4) |> max(1)
      magnitude = :math.pow(10, max(0, floor(:math.log10(step)))) |> trunc()

      4 * (ceil(step / magnitude) * magnitude)
    end
  end

  defp donut_segments(status_counts) do
    [
      %{
        label: "E-Invoice Generated",
        value: status_counts["E-Invoice Generated"] || 0,
        tone: :strong
      },
      %{label: "Draft", value: status_counts["Draft"] || 0, tone: :medium},
      # :positive, not :soft, which is the failure red.
      %{label: "Paid", value: status_counts["Paid"] || 0, tone: :positive},
      %{label: "Cancelled", value: status_counts["Cancelled"] || 0, tone: :faint}
    ]
    |> Enum.reject(&(&1.value == 0))
  end

  defp compliance_items(obligations, today) do
    obligations
    |> Compliance.upcoming(today, 4)
    |> Enum.map(fn obligation ->
      %{
        month: Calendar.strftime(obligation.due_date, "%b"),
        day: Calendar.strftime(obligation.due_date, "%d"),
        title: "#{obligation.type} · #{obligation.period_label}",
        due_text: due_text(obligation),
        due_class: due_class(obligation),
        tone: due_tone(obligation)
      }
    end)
  end

  defp due_text(%{status: "Overdue", days_until: days}),
    do: "Overdue by #{abs(days)} #{plural(abs(days), "day")}"

  defp due_text(%{days_until: 0}), do: "Due today"
  defp due_text(%{days_until: days}), do: "Due in #{days} #{plural(days, "day")}"

  defp due_tone(%{status: "Overdue"}), do: :overdue
  defp due_tone(%{days_until: days}) when days <= 3, do: :due_soon
  defp due_tone(_obligation), do: :neutral

  defp due_class(%{status: "Overdue"}), do: "text-error"
  defp due_class(%{days_until: days}) when days <= 3, do: "text-warning"
  defp due_class(_obligation), do: "text-base-content/45"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
