defmodule QuantumBillingWeb.ComplianceLive do
  @moduledoc """
  The Compliance page: filing status for the year, obligations, what is due
  next and a month calendar.

  The schedule comes from `Compliance` rules for this registration. A return
  marked filed from its detail panel is Filed; otherwise its status comes from
  the due date. Hand-added tasks join the same rows (with `:task`). `render/1`
  derives rows from the filter state each pass.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.ComplianceComponents
  import QuantumBillingWeb.DashboardComponents, only: [stat_card: 1]

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Compliance
  alias QuantumBilling.Compliance.Task
  alias QuantumBilling.Settings

  def mount(_params, _session, socket) do
    today = Date.utc_today()

    {:ok,
     socket
     |> assign(:page_title, "Compliance")
     |> assign(:active_nav, :compliance)
     |> assign(:today, today)
     |> load_rows()
     |> close_task_form()
     |> assign(:category, :all)
     |> assign(:status_filter, "All Status")
     |> assign(:calendar_year, today.year)
     |> assign(:calendar_month, today.month)
     |> assign(:selected_date, nil)
     |> assign(:selected, nil)
     |> assign(:filing_form, nil)}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply, assign(socket, :category, Compliance.category_key(category))}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    status = if status in Compliance.statuses(), do: status, else: "All Status"

    {:noreply, assign(socket, :status_filter, status)}
  end

  def handle_event("new_task", %{"kind" => kind}, socket) when kind in ["task", "reminder"] do
    {:noreply, open_task_form(socket, %Task{kind: kind}, kind)}
  end

  def handle_event("new_task", _params, socket), do: {:noreply, socket}

  def handle_event("edit_task", %{"id" => id}, socket) do
    case Compliance.get_task(socket.assigns.current_scope, id) do
      nil -> {:noreply, task_gone(socket)}
      task -> {:noreply, open_task_form(socket, task, task.kind)}
    end
  end

  def handle_event("cancel_task", _params, socket) do
    {:noreply, close_task_form(socket)}
  end

  def handle_event("validate_task", %{"task" => params}, socket) do
    form =
      socket.assigns.editing_task
      |> Compliance.change_task(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :task_form, form)}
  end

  def handle_event("save_task", %{"task" => params}, socket) do
    case save_task(socket, params) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> close_task_form()
         |> load_rows()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :task_form, to_form(changeset))}

      {:error, :not_open} ->
        {:noreply, socket}
    end
  end

  def handle_event("complete_task", %{"id" => id}, socket) do
    change_task(socket, id, &Compliance.complete_task/2)
  end

  def handle_event("reopen_task", %{"id" => id}, socket) do
    change_task(socket, id, &Compliance.reopen_task/2)
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    change_task(socket, id, &Compliance.delete_task/2)
  end

  def handle_event("prev_month", _params, socket) do
    {:noreply, shift_calendar(socket, -1)}
  end

  def handle_event("next_month", _params, socket) do
    {:noreply, shift_calendar(socket, 1)}
  end

  def handle_event("show_detail", %{"due" => due, "type" => type}, socket) do
    selected =
      case Date.from_iso8601(due) do
        {:ok, due} ->
          Enum.find(
            socket.assigns.obligations,
            &(&1.due_date == due and &1.type == type and is_nil(&1[:task]))
          )

        {:error, _invalid} ->
          nil
      end

    {:noreply, socket |> assign(:selected, selected) |> assign(:filing_form, nil)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, socket |> assign(:selected, nil) |> assign(:filing_form, nil)}
  end

  # The return being marked is always the open detail panel's, never a param.
  def handle_event("open_filing", _params, socket) do
    form =
      %{"filed_on" => Date.to_iso8601(socket.assigns.today)}
      |> Compliance.change_filing()
      |> to_form()

    {:noreply, assign(socket, :filing_form, form)}
  end

  def handle_event("cancel_filing", _params, socket) do
    {:noreply, assign(socket, :filing_form, nil)}
  end

  def handle_event("validate_filing", %{"filing" => params}, socket) do
    form =
      params
      |> Compliance.change_filing()
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :filing_form, form)}
  end

  def handle_event("save_filing", %{"filing" => params}, %{assigns: %{selected: %{}}} = socket) do
    %{type: type, period_key: period_key, period_label: label} = socket.assigns.selected

    case Compliance.mark_filed(socket.assigns.current_scope, type, period_key, params) do
      {:ok, _filing} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{type} for #{label} marked as filed.")
         |> refresh_selected()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :filing_form, to_form(changeset))}

      {:error, :unknown_obligation} ->
        {:noreply, filing_gone(socket)}
    end
  end

  def handle_event("undo_filing", _params, %{assigns: %{selected: %{}}} = socket) do
    %{type: type, period_key: period_key, period_label: label} = socket.assigns.selected

    case Compliance.undo_filed(socket.assigns.current_scope, type, period_key) do
      {:ok, _filing} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{type} for #{label} is no longer marked as filed.")
         |> refresh_selected()}

      {:error, _not_found} ->
        {:noreply, filing_gone(socket)}
    end
  end

  def handle_event(event, _params, socket) when event in ["save_filing", "undo_filing"] do
    {:noreply, socket}
  end

  # Clicking the selected day or an empty one clears the filter.
  def handle_event("select_day", %{"date" => date}, socket) do
    selected =
      with {:ok, date} <- Date.from_iso8601(date),
           false <- socket.assigns.selected_date == date,
           [_ | _] <- Compliance.on_date(socket.assigns.obligations, date) do
        date
      else
        _nothing_to_filter_by -> nil
      end

    {:noreply,
     socket
     |> assign(:selected_date, selected)
     |> assign(:selected, nil)
     |> assign(:filing_form, nil)}
  end

  def handle_event("clear_day", _params, socket) do
    {:noreply, assign(socket, :selected_date, nil)}
  end

  def handle_event("show_all", _params, socket) do
    {:noreply,
     socket
     |> assign(:category, :all)
     |> assign(:status_filter, "All Status")
     |> assign(:selected_date, nil)}
  end

  # Which returns are owed depends on the registration type.
  defp load_rows(socket) do
    today = socket.assigns.today
    scope = socket.assigns.current_scope

    obligations = Compliance.tracked_obligations(today, Settings.get_organization())
    tasks = scope |> Compliance.list_tasks() |> Enum.map(&Compliance.task_row(&1, today))

    assign(socket, :obligations, Enum.sort_by(obligations ++ tasks, & &1.due_date, Date))
  end

  defp open_task_form(socket, task, kind) do
    socket
    |> assign(:editing_task, task)
    |> assign(:task_kind, kind)
    |> assign(:task_form, to_form(Compliance.change_task(task)))
  end

  defp close_task_form(socket) do
    socket
    |> assign(:editing_task, nil)
    |> assign(:task_kind, nil)
    |> assign(:task_form, nil)
  end

  defp save_task(%{assigns: %{editing_task: nil}}, _params), do: {:error, :not_open}

  defp save_task(%{assigns: %{editing_task: %Task{id: nil} = task}} = socket, params) do
    Compliance.create_task(socket.assigns.current_scope, task.kind, params)
  end

  defp save_task(%{assigns: %{editing_task: task}} = socket, params) do
    Compliance.update_task(socket.assigns.current_scope, task, params)
  end

  defp change_task(socket, id, action) do
    scope = socket.assigns.current_scope

    case Compliance.get_task(scope, id) do
      nil ->
        {:noreply, task_gone(socket)}

      task ->
        {:ok, _task} = action.(scope, task)
        {:noreply, socket |> assign(:selected, nil) |> load_rows()}
    end
  end

  # Reloads the rows and the open panel, so both show the new status.
  defp refresh_selected(socket) do
    %{type: type, due_date: due_date} = socket.assigns.selected
    socket = socket |> assign(:filing_form, nil) |> load_rows()

    selected =
      Enum.find(
        socket.assigns.obligations,
        &(&1.type == type and &1.due_date == due_date and is_nil(&1[:task]))
      )

    assign(socket, :selected, selected)
  end

  defp filing_gone(socket) do
    socket
    |> put_flash(:error, "That return has changed. The page has been refreshed.")
    |> refresh_selected()
  end

  defp task_gone(socket) do
    socket
    |> put_flash(:error, "That item no longer exists.")
    |> load_rows()
  end

  defp repeat_label("weekly"), do: "Weekly"
  defp repeat_label("monthly"), do: "Monthly"
  defp repeat_label("quarterly"), do: "Quarterly"
  defp repeat_label("yearly"), do: "Yearly"
  defp repeat_label(_none), do: nil

  defp row_id(%{task: %Task{id: id}}), do: "task-#{id}"
  defp row_id(row), do: "obligation-#{row.type}-#{row.due_date}"

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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        Compliance
        <:subtitle>
          {if Scope.vat?(@current_scope),
            do: "Your compliance tasks and reminders",
            else: "Track your GST compliance and filing status"}
        </:subtitle>

        <:actions>
          <div class="flex flex-wrap items-center gap-2">
            <a href="#filing-calendar" phx-click="show_all" class={secondary_button_class()}>
              <.icon name="hero-calendar-days" class="size-4" /> View Filing Calendar
            </a>
            <button
              id="add-reminder"
              type="button"
              phx-click="new_task"
              phx-value-kind="reminder"
              class={secondary_button_class()}
            >
              <.icon name="hero-bell" class="size-4" /> Add reminder
            </button>
            <button
              id="add-task"
              type="button"
              phx-click="new_task"
              phx-value-kind="task"
              class={action_button_class()}
            >
              <.icon name="hero-plus" class="size-4" /> Add task
            </button>
          </div>
        </:actions>
      </.header>

      <.task_dialog
        :if={@task_form}
        form={@task_form}
        kind={@task_kind}
        editing?={@editing_task.id != nil}
        author?={@editing_task.id == nil or @editing_task.created_by_id == @current_scope.user.id}
      />

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_card
          label="Total Tracked"
          value={Integer.to_string(@summary.total)}
          icon="hero-document-text"
          tone={:info}
          delta_text={@fy_label}
          delta_class="text-base-content/45"
        />
        <.stat_card
          label="Completed"
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

      <%!-- Grid items-start so short task lists end right after the rows without a large blank area. --%>
      <div class="mt-3 grid grid-cols-1 items-start gap-3 lg:grid-cols-3">
        <.card class="flex flex-col lg:col-span-2">
          <div class="mb-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <h2 class="text-sm font-semibold tracking-tight">Compliance Tasks</h2>

            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class={secondary_button_class()}>
                <.icon name="hero-funnel" class="size-4" /> {@status_filter}
                <.icon name="hero-chevron-down" class="size-4" />
              </div>

              <ul
                tabindex="0"
                class="dropdown-content menu z-30 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
              >
                <li :for={status <- Compliance.statuses()}>
                  <a phx-click="filter_status" phx-value-status={status}>{status}</a>
                </li>
              </ul>
            </div>
          </div>
          <.tabs categories={Compliance.category_tabs(@obligations)} active={@category} />

          <%!-- Shows the calendar's day filter and a way to clear it. --%>
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
            <.obligation_detail obligation={@selected} filing_form={@filing_form} />
          </div>

          <%!-- Separate empty states: no data at all vs. a filter that excluded everything. --%>
          <div :if={@obligations == [] and Scope.vat?(@current_scope)} id="vat-compliance-empty">
            <.empty_state
              icon="hero-shield-check"
              title="No tasks yet"
              description="VAT returns are not tracked automatically. Add your own tasks and reminders for your filing dates."
            />
          </div>
          <.empty_state
            :if={@obligations == [] and not Scope.vat?(@current_scope)}
            icon="hero-shield-check"
            title="No GST registration on file"
            description="Add your GSTIN under Settings › Organization and the filing calendar for your registration will be tracked here. You can add your own tasks and reminders at any time."
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
          <%!-- Table wrapper with max height scroll rather than forcing a 26rem empty min-height --%>
          <div :if={@rows != []} class="mt-4 max-h-[32rem] overflow-y-auto overflow-x-auto">
            <table class="w-full">
              <thead class="sticky top-0 z-10 bg-base-100">
                <tr class={[
                  table_head_class(),
                  "[&>th]:sticky [&>th]:top-0 [&>th]:bg-base-100",
                  "[&>th]:border-b [&>th]:border-base-300"
                ]}>
                  <th class="w-2/5 min-w-[14rem] pr-4 text-left">Compliance Type</th>

                  <th class="w-[8rem] whitespace-nowrap pr-4 text-left">Period</th>

                  <th class="w-[8rem] whitespace-nowrap pr-4 text-left">Due Date</th>

                  <th class="w-[7rem] pr-4 text-left">Status</th>

                  <th class="w-[8rem] whitespace-nowrap pr-4 text-left">Filed / Done</th>

                  <th class="w-[7rem] text-right">Actions</th>
                </tr>
              </thead>

                <tbody>
                  <tr
                    :for={row <- @rows}
                    id={row_id(row)}
                    class={table_row_class()}
                  >
                    <td class="py-2.5 pr-4">
                      <p class="flex items-center gap-1.5 font-medium">
                        <span class="truncate">{row.type}</span>
                        <span
                          :if={row[:task]}
                          class="shrink-0 rounded-full border border-base-300 bg-base-200 px-1.5 text-2xs font-medium text-base-content/60"
                        >
                          Manual
                        </span>
                        <span
                          :if={row[:task] && row.task.private}
                          id={"task-private-#{row.task.id}"}
                          title="Only you can see this"
                          class="inline-flex shrink-0 items-center gap-1 rounded-full border border-base-300 bg-base-200 px-1.5 text-2xs font-medium text-base-content/60"
                        >
                          <.icon name="hero-lock-closed" class="size-3" />
                          <span>Private</span>
                        </span>
                      </p>

                      <p class="mt-0.5 flex flex-wrap items-center gap-x-2 text-xs text-base-content/60">
                        <span>{row.subtitle}</span>
                        <%= if row[:task] do %>
                          <span
                            :if={match?({:custom, _label}, row.category)}
                            id={"task-category-#{row.task.id}"}
                            class="inline-flex items-center gap-1 rounded-full bg-base-200 px-1.5 text-2xs font-medium text-base-content/70"
                          >
                            <.icon name="hero-tag" class="size-3" />
                            {Compliance.category_label(row.category)}
                          </span>
                          <span
                            :if={row.task.repeat != "none"}
                            id={"task-repeat-#{row.task.id}"}
                            class="inline-flex items-center gap-1"
                            title={"Repeats #{row.task.repeat}"}
                          >
                            <.icon name="hero-arrow-path" class="size-3" /> {repeat_label(
                              row.task.repeat
                            )}
                          </span>
                          <span
                            :if={row.task.remind_at}
                            class="inline-flex items-center gap-1"
                            title="Reminder time"
                          >
                            <.icon name="hero-clock" class="size-3" />
                            {Calendar.strftime(row.task.remind_at, "%I:%M %p")}
                          </span>
                          <span
                            :if={row.task.email_reminder}
                            class="inline-flex items-center"
                            title="Also by email"
                          >
                            <.icon name="hero-envelope" class="size-3" />
                            <span class="sr-only">Also by email</span>
                          </span>
                        <% end %>
                      </p>

                      <p
                        :if={row[:task] && row.task.notes}
                        class="mt-0.5 line-clamp-2 max-w-xs text-xs text-base-content/45"
                      >
                        {row.task.notes}
                      </p>
                    </td>

                    <td class="py-2.5 pr-4 text-base-content/60">{row.period_label}</td>

                    <td class="py-2.5 pr-4 text-base-content/60">{format_date(row.due_date)}</td>

                    <td class="py-2.5 pr-4"><.status_badge status={row.status} /></td>

                    <td class="py-2.5 pr-4 text-base-content/60">{format_date(row.filed_on)}</td>

                    <td class="py-2.5 text-right">
                      <div :if={row[:task]} class="flex justify-end gap-1">
                        <button
                          :if={row.status != "Done"}
                          id={"task-complete-#{row.task.id}"}
                          type="button"
                          phx-click="complete_task"
                          phx-value-id={row.task.id}
                          class={row_action_class()}
                          title={"Mark #{row.type} done"}
                          aria-label={"Mark #{row.type} done"}
                        >
                          <.icon name="hero-check" class="size-4" />
                        </button>
                        <button
                          :if={row.status == "Done"}
                          id={"task-reopen-#{row.task.id}"}
                          type="button"
                          phx-click="reopen_task"
                          phx-value-id={row.task.id}
                          class={row_action_class()}
                          title={"Reopen #{row.type}"}
                          aria-label={"Reopen #{row.type}"}
                        >
                          <.icon name="hero-arrow-uturn-left" class="size-4" />
                        </button>
                        <button
                          id={"task-edit-#{row.task.id}"}
                          type="button"
                          phx-click="edit_task"
                          phx-value-id={row.task.id}
                          class={row_action_class()}
                          title={"Edit #{row.type}"}
                          aria-label={"Edit #{row.type}"}
                        >
                          <.icon name="hero-pencil-square" class="size-4" />
                        </button>
                        <button
                          id={"task-delete-#{row.task.id}"}
                          type="button"
                          phx-click="delete_task"
                          phx-value-id={row.task.id}
                          data-confirm={"Delete #{row.type}?"}
                          class={row_action_class()}
                          title={"Delete #{row.type}"}
                          aria-label={"Delete #{row.type}"}
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </button>
                      </div>

                      <div :if={!row[:task]} class="flex justify-end gap-1">
                        <button
                          id={"view-#{row_id(row)}"}
                          type="button"
                          phx-click="show_detail"
                          phx-value-due={row.due_date}
                          phx-value-type={row.type}
                          class={row_action_class()}
                          title={"View #{row.type} details"}
                          aria-label={"View #{row.type} details"}
                        >
                          <.icon name="hero-eye" class="size-4" />
                        </button>

                        <%!-- GSTR-1 only: the other returns are summaries derived from it. --%>
                        <.link
                          :if={row.type == "GSTR-1"}
                          href={~p"/reports/gstr1/export?#{[period: row.period_key]}"}
                          class={row_action_class()}
                          title={"Download #{row.type} JSON for #{row.period_label}"}
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

        <div class="flex flex-col gap-3">
          <.card>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-sm font-semibold tracking-tight">Upcoming Due Dates</h2>

              <button
                type="button"
                phx-click="show_all"
                class="text-xs font-medium text-base-content/60 hover:text-base-content"
              >
                View All
              </button>
            </div>

            <ul :if={@upcoming != []} class="space-y-3">
              <.due_date_row :for={obligation <- @upcoming} obligation={obligation} />
            </ul>

            <.empty_state
              :if={@upcoming == []}
              icon="hero-check-circle"
              title="Nothing due"
              description={
                cond do
                  @obligations != [] -> "Every obligation for this year is filed."
                  Scope.vat?(@current_scope) -> "Your tasks and reminders appear here."
                  true -> "Filing deadlines appear here once a GSTIN is saved in Settings."
                end
              }
            />
          </.card>

          <.card id="filing-calendar" class="flex-1">
            <h2 class="mb-2.5 text-sm font-semibold tracking-tight">Compliance Calendar</h2>

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
