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

  alias QuantumBilling.Compliance
  alias QuantumBilling.Invoices
  alias QuantumBilling.Payments.QRCode

  def mount(_params, _session, socket) do
    if connected?(socket), do: Invoices.subscribe()

    {:ok, socket |> assign(:qr_modal_invoice, nil) |> assign_dashboard()}
  end

  def handle_event("show_qr_modal", %{"id" => id}, socket) do
    invoice = Invoices.get_invoice(id)
    {:noreply, assign(socket, :qr_modal_invoice, invoice)}
  end

  def handle_event("close_qr_modal", _params, socket) do
    {:noreply, assign(socket, :qr_modal_invoice, nil)}
  end

  # Every panel is derived from the invoice set, so a change to it rebuilds all
  # of them together rather than leaving the cards and the charts disagreeing.
  def handle_info({:invoice_changed, _invoice}, socket) do
    {:noreply, assign_dashboard(socket)}
  end

  # Counts come from aggregate queries and the table from a limited one. The
  # dashboard used to load every invoice in the database in order to count them
  # and show five, on every page load and on every change anywhere in the
  # application.
  defp assign_dashboard(socket) do
    today = Date.utc_today()
    totals = Invoices.totals()
    month = Invoices.month_totals(today)
    status_counts = Invoices.status_counts()
    chart_months = billed_months(Invoices.monthly_tax_split(6, today))
    obligations = Compliance.obligations(today)

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:active_nav, :dashboard)
    |> assign(:stats, stats(totals, month, obligations))
    |> assign(:chart_months, chart_months)
    |> assign(:chart_max, chart_max(chart_months))
    |> assign(:donut_segments, donut_segments(status_counts))
    |> assign(:donut_total, totals.count)
    |> assign(:invoices, Invoices.recent_invoices(5))
    |> assign(:compliance_items, compliance_items(obligations, today))
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
          <.bar_chart :if={@chart_months != []} months={@chart_months} max={@chart_max} />
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

              <:action :let={row}>
                <button
                  class={row_action_class()}
                  aria-label="View QR code"
                  phx-click="show_qr_modal"
                  phx-value-id={row.id}
                >
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

      <%!-- Dashboard Quick Invoice QR Modal --%>
      <div
        :if={@qr_modal_invoice}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      >
        <div class="w-full max-w-md rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl space-y-4">
          <div class="flex items-center justify-between border-b border-base-200 pb-3">
            <div>
              <h3 class="text-base font-bold">UPI Payment QR Code</h3>
              <p class="text-xs text-base-content/60">
                Invoice {@qr_modal_invoice.invoice_number} &bull; Total:
                <strong class="text-emerald-600">₹{@qr_modal_invoice.grand_total ||
                  @qr_modal_invoice.amount}</strong>
              </p>
            </div>
            <button
              type="button"
              phx-click="close_qr_modal"
              class="text-base-content/50 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <div class="flex flex-col items-center justify-center p-4 bg-white rounded-xl border border-base-200 shadow-inner">
            <.upi_qr
              invoice={@qr_modal_invoice}
              size_class="w-48 h-48"
              caption="Scan with GPay, PhonePe, Paytm, BHIM or any UPI App"
              caption_class="mt-3 text-xs font-semibold text-gray-800 text-center"
            />
          </div>

          <div :if={@qr_modal_invoice.signed_qr_code} class="border-t border-base-200 pt-3">
            <p class="text-xs font-bold mb-1 text-center">
              Government E-Invoice Verified (Signed QR)
            </p>
            <div class="w-32 h-32 mx-auto bg-white p-2 rounded-lg border border-base-200">
              {raw(QRCode.generate_svg(@qr_modal_invoice.signed_qr_code))}
            </div>
          </div>

          <div class="flex items-center justify-between gap-2 pt-2 border-t border-base-200">
            <.link
              href={~p"/pay/#{@qr_modal_invoice.public_token || "tok_123"}"}
              target="_blank"
              class="btn btn-sm btn-outline btn-primary text-xs"
            >
              <.icon name="hero-globe-alt" class="size-3.5" /> Public Payment Link
            </.link>
            <button
              type="button"
              phx-click="close_qr_modal"
              class="btn btn-sm btn-ghost text-xs"
            >
              Close
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Every card is a figure this system actually holds. They used to be three
  # hardcoded zeros and a count, which is indistinguishable from a business
  # that has issued nothing — and stayed that way no matter how much was
  # invoiced.
  defp stats(totals, month, obligations) do
    pending_returns =
      Enum.count(obligations, &(&1.status in ["Pending", "Overdue"] and &1.category == :returns))

    overdue_returns = Enum.count(obligations, &(&1.status == "Overdue"))

    [
      %{
        label: "Invoices Issued",
        value: Integer.to_string(totals.count),
        icon: "hero-document-text",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: "#{month.count} this month",
        delta_class: "text-base-content/45",
        delta_icon: nil
      },
      %{
        label: "Current Month Tax Liability",
        value: rupees(month.tax),
        icon: "hero-currency-rupee",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: "on #{rupees(month.taxable_value)} taxable",
        delta_class: "text-base-content/45",
        delta_icon: nil
      },
      %{
        label: "Outstanding Receivables",
        value: rupees(totals.outstanding),
        icon: "hero-banknotes",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text: "#{totals.paid_count} paid in full",
        delta_class: "text-base-content/45",
        delta_icon: nil
      },
      %{
        label: "Pending GST Returns",
        value: Integer.to_string(pending_returns),
        icon: "hero-calendar-days",
        icon_class: "bg-base-200 text-base-content/60",
        delta_text:
          if(overdue_returns > 0, do: "#{overdue_returns} overdue", else: "None overdue"),
        delta_class: if(overdue_returns > 0, do: "text-error", else: "text-base-content/45"),
        delta_icon: if(overdue_returns > 0, do: "hero-exclamation-triangle", else: nil)
      }
    ]
  end

  # Six months of zeros is not a chart, it is an empty state — and drawing one
  # makes a business that has issued nothing look like one whose invoices went
  # missing.
  defp billed_months(months) do
    if Enum.all?(months, &(&1.cgst_sgst == 0 and &1.igst == 0)), do: [], else: months
  end

  # The chart scales against the tallest bar, rounded up so the gridlines land
  # on round numbers. A fixed ceiling made every real invoice overflow the box.
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

  # Real counts, in a fixed order so the ring's colours stay stable, with empty
  # statuses dropped.
  defp donut_segments(status_counts) do
    [
      %{
        label: "E-Invoice Generated",
        value: status_counts["E-Invoice Generated"] || 0,
        tone: :strong
      },
      %{label: "Draft", value: status_counts["Draft"] || 0, tone: :medium},
      %{label: "Paid", value: status_counts["Paid"] || 0, tone: :soft},
      %{label: "Cancelled", value: status_counts["Cancelled"] || 0, tone: :faint}
    ]
    |> Enum.reject(&(&1.value == 0))
  end

  # The next statutory deadlines, from the same calendar the Compliance page
  # shows — so the dashboard and that page cannot disagree about what is due.
  defp compliance_items(obligations, today) do
    obligations
    |> Compliance.upcoming(today, 4)
    |> Enum.map(fn obligation ->
      %{
        month: Calendar.strftime(obligation.due_date, "%b"),
        day: Calendar.strftime(obligation.due_date, "%d"),
        title: "#{obligation.type} · #{obligation.period_label}",
        due_text: due_text(obligation),
        due_class: due_class(obligation)
      }
    end)
  end

  defp due_text(%{status: "Overdue", days_until: days}),
    do: "Overdue by #{abs(days)} #{plural(abs(days), "day")}"

  defp due_text(%{days_until: 0}), do: "Due today"
  defp due_text(%{days_until: days}), do: "Due in #{days} #{plural(days, "day")}"

  defp due_class(%{status: "Overdue"}), do: "text-error"
  defp due_class(%{days_until: days}) when days <= 3, do: "text-warning"
  defp due_class(_obligation), do: "text-base-content/45"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
