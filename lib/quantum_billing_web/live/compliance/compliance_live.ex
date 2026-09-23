defmodule QuantumBillingWeb.ComplianceLive do
  @moduledoc """
  The Compliance page: filing status across the financial year, the obligations
  themselves, what falls due next, and a month calendar.

  Everything is derived from `QuantumBilling.Compliance`, which generates the
  schedule from the statutory rules rather than storing it, narrowed to what
  this organisation's own GST registration actually owes. Nothing is filed
  yet — that needs the filings table — so obligations resolve to Pending or
  Overdue on dates alone.

  `mount/3` assigns raw filter and calendar state; `handle_event/3` only ever
  updates that state; `render/1` re-derives the visible rows on every pass, so
  there is a single source of truth.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.ComplianceComponents
  import QuantumBillingWeb.DashboardComponents, only: [stat_card: 1]

  alias QuantumBilling.Compliance
  alias QuantumBilling.Settings

  def mount(_params, _session, socket) do
    today = Date.utc_today()

    # The organisation's registration is what decides which returns are owed —
    # a composition dealer and a regular taxpayer do not file the same forms —
    # so the calendar is resolved against it rather than shown in full.
    obligations = Compliance.tracked_obligations(today, Settings.get_organization())

    {:ok,
     socket
     |> assign(:page_title, "Compliance")
     |> assign(:active_nav, :compliance)
     |> assign(:today, today)
     |> assign(:obligations, obligations)
     |> assign(:category, :all)
     |> assign(:status_filter, "All Status")
     |> assign(:calendar_year, today.year)
     |> assign(:calendar_month, today.month)
     |> assign(:selected_date, nil)
     |> assign(:selected, nil)}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply, assign(socket, :category, String.to_existing_atom(category))}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, assign(socket, :status_filter, status)}
  end

  def handle_event("prev_month", _params, socket) do
    {:noreply, shift_calendar(socket, -1)}
  end

  def handle_event("next_month", _params, socket) do
    {:noreply, shift_calendar(socket, 1)}
  end

  def handle_event("show_detail", %{"due" => due, "type" => type}, socket) do
    due = Date.from_iso8601!(due)

    selected =
      Enum.find(socket.assigns.obligations, &(&1.due_date == due and &1.type == type))

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :selected, nil)}
  end

  # A day in the calendar narrows the task list to that date, which is what a
  # calendar is for — the grid used to mark the deadlines and then refuse to
  # say anything about them. Clicking the same day again, or an empty one,
  # clears the narrowing rather than stranding the page on one date.
  def handle_event("select_day", %{"date" => date}, socket) do
    date = Date.from_iso8601!(date)
    already_selected? = socket.assigns.selected_date == date
    carries_obligations? = Compliance.on_date(socket.assigns.obligations, date) != []

    selected = if already_selected? or not carries_obligations?, do: nil, else: date

    {:noreply, socket |> assign(:selected_date, selected) |> assign(:selected, nil)}
  end

  def handle_event("clear_day", _params, socket) do
    {:noreply, assign(socket, :selected_date, nil)}
  end

  # "View All" and "View Filing Calendar" both clear any narrowing so the whole
  # year is visible, which is what both controls promise.
  def handle_event("show_all", _params, socket) do
    {:noreply,
     socket
     |> assign(:category, :all)
     |> assign(:status_filter, "All Status")
     |> assign(:selected_date, nil)}
  end

  defp shift_calendar(socket, months) do
    shifted =
      Date.new!(socket.assigns.calendar_year, socket.assigns.calendar_month, 1)
      |> Compliance.shift_months(months)

    socket
    |> assign(:calendar_year, shifted.year)
    |> assign(:calendar_month, shifted.month)
  end

  def render(assigns) do
    filtered =
      assigns.obligations
      |> Compliance.filter(%{category: assigns.category, status: assigns.status_filter})
      |> then(fn rows ->
        if assigns.selected_date, do: Compliance.on_date(rows, assigns.selected_date), else: rows
      end)

    assigns =
      assign(assigns,
        rows: filtered,
        summary: Compliance.summary(assigns.obligations),
        upcoming: Compliance.upcoming(assigns.obligations, assigns.today),
        weeks:
          Compliance.calendar_weeks(
            assigns.calendar_year,
            assigns.calendar_month,
            assigns.obligations
          ),
        fy_label: Compliance.financial_year_label(assigns.today)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        Compliance
        <:subtitle>Track your GST compliance and filing status</:subtitle>

        <:actions>
          <a href="#filing-calendar" phx-click="show_all" class={action_button_class()}>
            <.icon name="hero-calendar-days" class="size-4" /> View Filing Calendar
          </a>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_card
          label="Total Returns"
          value={Integer.to_string(@summary.total)}
          icon="hero-document-text"
          tone={:info}
          delta_text={@fy_label}
          delta_class="text-base-content/45"
        />
        <.stat_card
          label="Filed On Time"
          value={Integer.to_string(@summary.filed)}
          icon="hero-check-circle"
          tone={:success}
          delta_text={"#{@summary.filed_pct}%"}
          delta_class="text-success"
        />
        <.stat_card
          label="Pending"
          value={Integer.to_string(@summary.pending)}
          icon="hero-clock"
          tone={:warning}
          delta_text={"#{@summary.pending_pct}%"}
          delta_class="text-warning"
        />
        <.stat_card
          label="Overdue"
          value={Integer.to_string(@summary.overdue)}
          icon="hero-exclamation-circle"
          tone={:danger}
          delta_text={"#{@summary.overdue_pct}%"}
          delta_class="text-error"
        />
      </div>

      <div class="mt-3 grid grid-cols-1 gap-3 lg:grid-cols-3">
        <.card class="lg:col-span-2">
          <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <h2 class="text-sm font-semibold tracking-tight">Compliance Tasks</h2>

            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class={secondary_button_class()}>
                <.icon name="hero-funnel" class="size-4" /> {@status_filter}
                <.icon name="hero-chevron-down" class="size-4" />
              </div>

              <ul
                tabindex="0"
                class="dropdown-content menu z-10 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
              >
                <li :for={status <- Compliance.statuses()}>
                  <a phx-click="filter_status" phx-value-status={status}>{status}</a>
                </li>
              </ul>
            </div>
          </div>
          <.tabs categories={Compliance.categories()} active={@category} />

          <%!-- Says which day the calendar narrowed the list to, and offers the
          way back out. A filter applied from another card is invisible
          otherwise, and an empty table reads as a bug. --%>
          <div :if={@selected_date} class="mt-4 flex items-center gap-2">
            <span class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-200 px-3 py-1 text-xs font-medium">
              <.icon name="hero-calendar-days" class="size-3.5 text-base-content/60" />
              Due {format_date(@selected_date)}
              <button
                type="button"
                phx-click="clear_day"
                class="text-base-content/45 transition-colors hover:text-base-content"
                aria-label="Clear the date filter"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </span>
          </div>

          <div :if={@selected} class="mt-4">
            <.obligation_detail obligation={@selected} />
          </div>

          <%!-- Two different empty states: nothing tracked at all is not the
          same as a filter that excluded everything, and telling someone with
          no data to "try another status" sends them chasing rows that do not
          exist. --%>
          <.empty_state
            :if={@obligations == []}
            icon="hero-shield-check"
            title="No GST registration on file"
            description="Add your GSTIN under Settings › Organization and the filing calendar for your registration will be tracked here."
          />
          <.empty_state
            :if={@obligations != [] and @rows == []}
            icon="hero-shield-check"
            title="Nothing matches these filters"
            description={
              if @selected_date,
                do: "Nothing is due on that date under the current category and status.",
                else: "Try another category or status."
            }
          />
          <div :if={@rows != []} class="overflow-x-auto">
            <table class="w-full">
              <thead>
                <tr class={table_head_class()}>
                  <th class="pr-4 text-left">Compliance Type</th>

                  <th class="pr-4 text-left">Period</th>

                  <th class="pr-4 text-left">Due Date</th>

                  <th class="pr-4 text-left">Status</th>

                  <th class="pr-4 text-left">Filed Date</th>

                  <th class="text-left">Actions</th>
                </tr>
              </thead>

              <tbody>
                <tr
                  :for={row <- @rows}
                  id={"obligation-#{row.type}-#{row.due_date}"}
                  class={table_row_class()}
                >
                  <td class="py-2.5 pr-4">
                    <p class="font-medium">{row.type}</p>

                    <p class="text-xs text-base-content/60">{row.subtitle}</p>
                  </td>

                  <td class="py-2.5 pr-4 text-base-content/60">{row.period_label}</td>

                  <td class="py-2.5 pr-4 text-base-content/60">{format_date(row.due_date)}</td>

                  <td class="py-2.5 pr-4"><.status_badge status={row.status} /></td>

                  <td class="py-2.5 pr-4 text-base-content/60">{format_date(row.filed_on)}</td>

                  <td class="py-2.5">
                    <div class="flex gap-1">
                      <button
                        type="button"
                        phx-click="show_detail"
                        phx-value-due={row.due_date}
                        phx-value-type={row.type}
                        class={row_action_class()}
                        aria-label={"View #{row.type} details"}
                      >
                        <.icon name="hero-eye" class="size-4" />
                      </button>

                      <%!-- The GSTR-1 JSON for *this* period, which is what the
                      offline tool uploads. Only GSTR-1 has an export: the other
                      returns are summaries derived from it, and a button that
                      downloads the wrong return is worse than no button. --%>
                      <.link
                        :if={row.type == "GSTR-1"}
                        href={~p"/reports/gstr1/export?#{[period: row.period_key]}"}
                        class={row_action_class()}
                        aria-label={"Download #{row.type} JSON for #{row.period_label}"}
                      >
                        <.icon name="hero-arrow-down-tray" class="size-4" />
                      </.link>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <p :if={@rows != []} class="mt-4 text-sm text-base-content/60">
            Showing 1 to {length(@rows)} of {length(@rows)} entries
          </p>
        </.card>

        <div class="space-y-4">
          <.card>
            <div class="mb-4 flex items-center justify-between">
              <h2 class="text-sm font-semibold tracking-tight">Upcoming Due Dates</h2>

              <button
                type="button"
                phx-click="show_all"
                class="text-xs font-medium text-base-content/60 hover:text-base-content"
              >
                View All
              </button>
            </div>

            <ul :if={@upcoming != []} class="space-y-4">
              <.due_date_row :for={obligation <- @upcoming} obligation={obligation} />
            </ul>

            <.empty_state
              :if={@upcoming == []}
              icon="hero-check-circle"
              title="Nothing due"
              description={
                if @obligations == [],
                  do: "Filing deadlines appear here once a GSTIN is saved in Settings.",
                  else: "Every obligation for this year is filed."
              }
            />
          </.card>

          <.card id="filing-calendar">
            <h2 class="mb-4 text-sm font-semibold tracking-tight">Compliance Calendar</h2>

            <.month_calendar
              weeks={@weeks}
              year={@calendar_year}
              month={@calendar_month}
              today={@today}
              selected={@selected_date}
            />
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
