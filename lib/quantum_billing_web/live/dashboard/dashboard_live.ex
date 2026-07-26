defmodule QuantumBillingWeb.DashboardLive do
  @moduledoc """
  The GST invoicing overview dashboard: stats, invoice trend chart,
  invoice status breakdown, recent invoices, and compliance calendar.

  All data below is hardcoded sample data pending the multi-tenant Ecto
  schema; each section is backed by a private helper function so it can be
  swapped for real Repo queries without touching `render/1`.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.DashboardComponents

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:active_nav, :dashboard)
     |> assign(:stats, stats())
     |> assign(:chart_months, chart_months())
     |> assign(:donut_segments, donut_segments())
     |> assign(:donut_total, 15_489)
     |> assign(:invoices, invoices())
     |> assign(:compliance_items, compliance_items())}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        Dashboard
        <:subtitle>Overview of your GST invoicing and compliance</:subtitle>
        <:actions>
          <.link navigate={~p"/invoices"} class={action_button_class()}>
            <.icon name="hero-plus" class="size-4" /> Create New GST Invoice
          </.link>
        </:actions>
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
          <.bar_chart months={@chart_months} />
        </.card>

        <.card>
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Invoices by Status</h2>
          <.donut_chart segments={@donut_segments} total={@donut_total} />
        </.card>
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-3">
        <.card class="lg:col-span-2">
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Recent Tax Invoices</h2>
          <div class="overflow-x-auto">
            <.table id="invoices" rows={@invoices}>
              <:col :let={row} label="Invoice #">{row.number}</:col>
              <:col :let={row} label="Date">{row.date}</:col>
              <:col :let={row} label="Customer GSTIN">{row.gstin}</:col>
              <:col :let={row} label="Tax Type">{row.tax_type}</:col>
              <:col :let={row} label="Total Amount">{row.amount}</:col>
              <:col :let={row} label="Status"><.status_badge status={row.status} /></:col>
              <:action>
                <button class={row_action_class()} aria-label="View QR code">
                  <.icon name="hero-qr-code" class="size-4" />
                </button>
              </:action>
            </.table>
          </div>
          <div class="mt-4 flex items-center justify-between text-sm text-base-content/60">
            <span>Showing 1 to 5 of 5 entries</span>
            <.link navigate={~p"/invoices"} class="font-medium text-base-content hover:underline">
              View all invoices &rarr;
            </.link>
          </div>
        </.card>

        <.card>
          <h2 class="mb-4 text-sm font-semibold tracking-tight">Compliance Calendar</h2>
          <ul class="space-y-4">
            <li :for={item <- @compliance_items} class="flex items-center gap-3">
              <.compliance_date_badge month={item.month} day={item.day} />
              <div>
                <p class="text-sm font-medium">{item.title}</p>
                <p class={["text-xs", item.due_class]}>{item.due_text}</p>
              </div>
            </li>
          </ul>
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

  defp stats do
    [
      %{
        label: "Total E-Invoices Generated",
        value: "15,489",
        icon: "hero-document-text",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: "+12.5% from last 6 months",
        delta_class: "text-success",
        delta_icon: "hero-arrow-trending-up"
      },
      %{
        label: "Current Month Tax Liability",
        value: "₹8,94,730",
        icon: "hero-currency-rupee",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: "+8.3% from last month",
        delta_class: "text-success",
        delta_icon: "hero-arrow-trending-up"
      },
      %{
        label: "Current Month ITC Available",
        value: "₹6,45,210",
        icon: "hero-arrow-trending-down",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: "+6.7% from last month",
        delta_class: "text-success",
        delta_icon: "hero-arrow-trending-up"
      },
      %{
        label: "Pending GSTR-3B Filings",
        value: "2",
        icon: "hero-calendar-days",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: "Due in 5 days",
        delta_class: "text-error",
        delta_icon: nil
      }
    ]
  end

  defp chart_months do
    [
      %{label: "Dec 2023", cgst_sgst: 1450, igst: 620},
      %{label: "Jan 2024", cgst_sgst: 1680, igst: 540},
      %{label: "Feb 2024", cgst_sgst: 1320, igst: 710},
      %{label: "Mar 2024", cgst_sgst: 1890, igst: 480},
      %{label: "Apr 2024", cgst_sgst: 1560, igst: 890},
      %{label: "May 2024", cgst_sgst: 1750, igst: 650}
    ]
  end

  defp donut_segments do
    [
      %{label: "Generated", value: 12_456, tone: :strong},
      %{label: "Pending", value: 1_245, tone: :medium},
      %{label: "Failed", value: 98, tone: :soft},
      %{label: "Cancelled", value: 1_690, tone: :faint}
    ]
  end

  defp invoices do
    [
      %{
        number: "INV-2024-15489",
        date: "28 May 2024",
        gstin: "27AAACPJ8542D1Z5",
        tax_type: "IGST",
        amount: "₹1,24,500.00",
        status: "E-Invoice Generated"
      },
      %{
        number: "INV-2024-15488",
        date: "27 May 2024",
        gstin: "29AABCU9603R1ZM",
        tax_type: "CGST + SGST",
        amount: "₹86,200.00",
        status: "E-Invoice Generated"
      },
      %{
        number: "INV-2024-15487",
        date: "26 May 2024",
        gstin: "07AAFCD5862R1ZV",
        tax_type: "IGST",
        amount: "₹2,45,000.00",
        status: "Pending E-Invoice"
      },
      %{
        number: "INV-2024-15486",
        date: "25 May 2024",
        gstin: "19AABCT3518Q1ZF",
        tax_type: "CGST + SGST",
        amount: "₹18,750.00",
        status: "Draft"
      },
      %{
        number: "INV-2024-15485",
        date: "24 May 2024",
        gstin: "06AAACG1234B1Z1",
        tax_type: "IGST",
        amount: "₹3,12,900.00",
        status: "E-Invoice Failed"
      }
    ]
  end

  defp compliance_items do
    [
      %{
        month: "Jun",
        day: "05",
        title: "GSTR-3B Filing",
        due_text: "Due in 5 days",
        due_class: "text-error"
      },
      %{
        month: "Jun",
        day: "11",
        title: "GSTR-1 Filing",
        due_text: "Due in 11 days",
        due_class: "text-warning"
      },
      %{
        month: "Jun",
        day: "20",
        title: "Annual Return (GSTR-9)",
        due_text: "Due in 20 days",
        due_class: "text-base-content/45"
      }
    ]
  end
end
