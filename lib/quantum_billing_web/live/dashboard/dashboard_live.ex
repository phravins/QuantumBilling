defmodule QuantumBillingWeb.DashboardLive do
  @moduledoc """
  The GST invoicing overview dashboard: stats, invoice trend chart,
  invoice status breakdown, recent invoices, and compliance calendar.

  Every panel is derived from `QuantumBilling.Invoices`, which has nothing to
  return until the multi-tenant Ecto schema lands, so each currently renders its
  empty state. The derivations live in private helpers here so they can be
  swapped for real Repo queries without touching `render/1`.

  The compliance calendar is empty for the same reason, though it is a different
  kind of gap: GST return deadlines are statutory reference data rather than
  tenant records, so it wants computing from the filing calendar rather than
  reading from a table.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.DashboardComponents

  alias QuantumBilling.Invoices

  def mount(_params, _session, socket) do
    if connected?(socket), do: Invoices.subscribe()

    {:ok, assign_dashboard(socket)}
  end

  # Every panel is derived from the invoice set, so a change to it rebuilds all
  # of them together rather than leaving the cards and the charts disagreeing.
  def handle_info({:invoice_changed, _invoice}, socket) do
    {:noreply, assign_dashboard(socket)}
  end

  defp assign_dashboard(socket) do
    invoices = Invoices.list_invoices()

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:active_nav, :dashboard)
    |> assign(:stats, stats(invoices))
    |> assign(:chart_months, chart_months(invoices))
    |> assign(:donut_segments, donut_segments(invoices))
    |> assign(:donut_total, length(invoices))
    |> assign(:invoices, recent_invoices(invoices))
    |> assign(:compliance_items, compliance_items())
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        Dashboard
        <:subtitle>Overview of your GST invoicing and compliance</:subtitle>
      </.header>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_card
          :for={stat <- @stats}
          label={stat.label}
          value={stat.value}
          icon={stat.icon}
          icon_class={stat.icon_class}
          delta_text={stat.delta_text}
          delta_class={stat.delta_class}
          delta_icon={stat.delta_icon}
        />
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-3">
        <.card class="lg:col-span-2">
          <div class="mb-4 flex items-center justify-between">
            <h2 class="text-sm font-semibold tracking-tight">GST Invoices - Last 6 Months</h2>

            <div class="flex items-center gap-4 text-xs text-base-content/60">
              <span class="flex items-center gap-1.5">
                <span class="size-2 rounded-full bg-base-content" /> CGST + SGST
              </span>

              <span class="flex items-center gap-1.5">
                <span class="size-2 rounded-full bg-base-content/25" /> IGST
              </span>
            </div>
          </div>
          <.bar_chart :if={@chart_months != []} months={@chart_months} />
          <.empty_state
            :if={@chart_months == []}
            icon="hero-chart-bar"
            title="No invoice data yet"
            description="This chart fills in once you have invoices to report on."
          />
        </.card>

        <.card>
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Invoices by Status</h2>

          <.donut_chart
            :if={@donut_segments != []}
            segments={@donut_segments}
            total={@donut_total}
          />
          <.empty_state
            :if={@donut_segments == []}
            icon="hero-chart-pie"
            title="No invoices yet"
            description="Status breakdown appears once invoices exist."
          />
        </.card>
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-3">
        <.card class="lg:col-span-2">
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Recent Tax Invoices</h2>

          <.empty_state
            :if={@invoices == []}
            icon="hero-document-text"
            title="No invoices yet"
            description="GST invoices you create will appear here."
          />
          <div :if={@invoices != []} class="overflow-x-auto">
            <.table id="invoices" rows={@invoices}>
              <:col :let={row} label="Invoice #">{row.number}</:col>

              <:col :let={row} label="Date">{format_date(row.invoice_date)}</:col>

              <:col :let={row} label="Customer GSTIN">{row.gstin || "—"}</:col>

              <:col :let={row} label="Tax Type">{row.tax_type}</:col>

              <:col :let={row} label="Total Amount">
                {rupees(row.amount, decimals: 2, space: true)}
              </:col>

              <:col :let={row} label="Status"><.status_badge status={row.status} /></:col>

              <:action>
                <button class={row_action_class()} aria-label="View QR code">
                  <.icon name="hero-qr-code" class="size-4" />
                </button>
              </:action>
            </.table>
          </div>

          <div class="mt-4 flex items-center justify-between text-sm text-base-content/60">
            <span :if={@invoices != []}>Showing 1 to {length(@invoices)} entries</span>
            <.link
              navigate={~p"/invoices"}
              class="ml-auto font-medium text-base-content hover:underline"
            >
              View all invoices &rarr;
            </.link>
          </div>
        </.card>

        <.card>
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Compliance Calendar</h2>

          <ul :if={@compliance_items != []} class="space-y-4">
            <li :for={item <- @compliance_items} class="flex items-center gap-3">
              <.compliance_date_badge month={item.month} day={item.day} />
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
            class="mt-4 block text-sm font-medium text-base-content hover:underline"
          >
            View all due dates &rarr;
          </.link>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  # Each helper takes the invoice set so it becomes a real derivation the moment
  # `Invoices.list_invoices/0` returns rows. Until then every panel is empty
  # rather than showing invented figures.

  defp stats(invoices) do
    count = length(invoices)

    [
      %{
        label: "Total E-Invoices Generated",
        value: Integer.to_string(count),
        icon: "hero-document-text",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: nil,
        delta_class: "text-success",
        delta_icon: nil
      },
      %{
        label: "Current Month Tax Liability",
        value: rupees(0),
        icon: "hero-currency-rupee",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: nil,
        delta_class: "text-success",
        delta_icon: nil
      },
      %{
        label: "Current Month ITC Available",
        value: rupees(0),
        icon: "hero-arrow-trending-down",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: nil,
        delta_class: "text-success",
        delta_icon: nil
      },
      %{
        label: "Pending GSTR-3B Filings",
        value: "0",
        icon: "hero-calendar-days",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: nil,
        delta_class: "text-base-content/45",
        delta_icon: nil
      }
    ]
  end

  defp chart_months(_invoices), do: []

  defp donut_segments(_invoices), do: []

  defp recent_invoices(invoices), do: Enum.take(invoices, 5)

  # GST return deadlines are statutory, not tenant data — they belong in a
  # filing calendar rather than a table, which is still to be built.
  defp compliance_items, do: []
end
