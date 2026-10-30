defmodule QuantumBillingWeb.ComplianceComponents do
  @moduledoc """
  Building blocks for the Compliance page: the category tabs, the month
  calendar and the upcoming-due-dates rail.

  Colour here is confined to status — the pills and the calendar's day markers —
  which is the one place `QuantumBillingWeb.SharedComponents.status_badge/1`
  already sanctions it. Everything else stays monochrome.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1, input: 1]
  import QuantumBillingWeb.DashboardComponents, only: [compliance_date_badge: 1]

  import QuantumBillingWeb.SharedComponents,
    only: [action_button_class: 0, secondary_button_class: 0]

  alias Phoenix.LiveView.JS
  alias QuantumBilling.Compliance
  alias QuantumBillingWeb.Format

  @doc """
  Renders the All / Returns / Payments / Other Compliances tab row.
  """
  attr :categories, :list, required: true
  attr :active, :atom, required: true

  def tabs(assigns) do
    ~H"""
    <div class="-mb-px flex items-center gap-4 border-b border-base-300">
      <button
        :for={{key, label} <- @categories}
        type="button"
        phx-click="filter_category"
        phx-value-category={key}
        class={[
          "border-b-2 pb-2.5 text-sm transition-colors",
          if(@active == key,
            do: "border-base-content font-medium text-base-content",
            else: "border-transparent text-base-content/60 hover:text-base-content"
          )
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  @doc """
  Renders one entry of the upcoming-due-dates rail.

  `days_until` is signed: negative means the due date has passed.
  """
  attr :obligation, :map, required: true

  def due_date_row(assigns) do
    ~H"""
    <li class="flex items-center gap-3">
      <.compliance_date_badge
        month={Calendar.strftime(@obligation.due_date, "%b")}
        day={Calendar.strftime(@obligation.due_date, "%d")}
        tone={badge_tone(@obligation.days_until)}
      />
      <div class="min-w-0 flex-1">
        <p class="truncate text-sm font-medium">
          {@obligation.type}<span :if={!@obligation[:task]}> - {@obligation.period_label}</span>
        </p>

        <p class={["text-xs", countdown_class(@obligation.days_until)]}>
          {countdown(@obligation.days_until)}
        </p>
      </div>

      <span class={[
        "inline-flex shrink-0 items-center rounded-full border px-2 py-0.5 text-xs font-medium",
        status_tone(@obligation.status)
      ]}>
        {@obligation.status}
      </span>
    </li>
    """
  end

  @doc """
  Formats a signed day count the way the rail reads it.
  """
  def countdown(0), do: "Due today"
  def countdown(1), do: "Due tomorrow"
  def countdown(-1), do: "Overdue by 1 day"
  def countdown(days) when days > 1, do: "Due in #{days} days"
  def countdown(days), do: "Overdue by #{abs(days)} days"

  defp countdown_class(days) when days < 0, do: "text-error"
  defp countdown_class(days) when days <= 7, do: "text-warning"
  defp countdown_class(_days), do: "text-base-content/45"

  defp badge_tone(days) when days < 0, do: :overdue
  defp badge_tone(days) when days <= 7, do: :due_soon
  defp badge_tone(_days), do: :neutral

  # Literal class strings so Tailwind emits them.
  defp status_tone(status) when status in ["Filed", "Done"],
    do:
      "border-emerald-200 bg-emerald-50 text-emerald-700 " <>
        "dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300"

  defp status_tone("Pending"),
    do:
      "border-amber-200 bg-amber-50 text-amber-700 " <>
        "dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300"

  defp status_tone("Overdue"),
    do:
      "border-rose-200 bg-rose-50 text-rose-700 " <>
        "dark:border-rose-900 dark:bg-rose-950 dark:text-rose-300"

  defp status_tone(_other), do: "border-base-300 bg-base-200 text-base-content/60"

  defp dot_tone(status) when status in ["Filed", "Done"], do: "bg-emerald-500"
  defp dot_tone("Pending"), do: "bg-amber-500"
  defp dot_tone("Overdue"), do: "bg-rose-500"
  defp dot_tone(_other), do: "bg-base-content/30"

  @doc """
  Renders a month grid marking the days that carry an obligation.

  `weeks` comes from `QuantumBilling.Compliance.calendar_weeks/3`.
  """
  attr :weeks, :list, required: true
  attr :year, :integer, required: true
  attr :month, :integer, required: true
  attr :today, Date, required: true
  attr :selected, Date, default: nil, doc: "the day the task list is narrowed to"

  def month_calendar(assigns) do
    ~H"""
    <div>
      <div class="mb-3 flex items-center justify-between">
        <button
          type="button"
          phx-click="prev_month"
          class="flex size-7 items-center justify-center rounded-field text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
          aria-label="Previous month"
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </button>

        <p class="text-sm font-medium">
          {Calendar.strftime(Date.new!(@year, @month, 1), "%B %Y")}
        </p>

        <button
          type="button"
          phx-click="next_month"
          class="flex size-7 items-center justify-center rounded-field text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
          aria-label="Next month"
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>

      <div class="grid grid-cols-7 gap-y-1 text-center">
        <span :for={day <- ~w(Sun Mon Tue Wed Thu Fri Sat)} class="pb-1 text-2xs text-base-content/45">
          {day}
        </span>

        <button
          :for={cell <- List.flatten(@weeks)}
          type="button"
          phx-click="select_day"
          phx-value-date={cell.date}
          disabled={cell.obligations == [] and cell.date != @selected}
          class={[
            "flex flex-col items-center gap-0.5 rounded-field py-0.5 transition-colors",
            "disabled:cursor-default enabled:cursor-pointer enabled:hover:bg-base-200/70"
          ]}
          aria-pressed={to_string(cell.date == @selected)}
          aria-label={day_label(cell)}
        >
          <span class={[
            "flex size-7 items-center justify-center rounded-full text-xs",
            cell.date == @selected && "ring-2 ring-base-content ring-offset-1 ring-offset-base-100",
            cond do
              cell.date == @today -> "bg-base-content font-semibold text-base-100"
              not cell.in_month? -> "text-base-content/25"
              cell.obligations != [] -> "bg-base-200 font-medium"
              true -> "text-base-content/60"
            end
          ]}>
            {cell.date.day}
          </span>

          <span class="flex h-1.5 items-center gap-0.5">
            <span
              :for={obligation <- Enum.take(cell.obligations, 3)}
              class={["size-1.5 rounded-full", dot_tone(obligation.status)]}
            />
          </span>
        </button>
      </div>

      <div class="mt-3 flex items-center justify-center gap-3 border-t border-base-300 pt-3">
        <span
          :for={
            {label, status} <- [
              {"Filed or done", "Filed"},
              {"Pending", "Pending"},
              {"Overdue", "Overdue"}
            ]
          }
          class="flex items-center gap-1.5 text-xs text-base-content/60"
        >
          <span class={["size-2 rounded-full", dot_tone(status)]} />{label}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  Renders the detail panel shown when a row's view action is used.

  With no filing record there is nothing to download, so this explains the
  obligation instead: what it is, the period it covers and when it is due.
  """
  attr :obligation, :map, required: true

  def obligation_detail(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 p-4">
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-sm font-semibold tracking-tight">
            {@obligation.type} &mdash; {@obligation.period_label}
          </p>

          <p class="mt-0.5 text-xs text-base-content/60">{@obligation.subtitle}</p>
        </div>

        <button
          type="button"
          phx-click="close_detail"
          class="flex size-7 items-center justify-center rounded-field text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
          aria-label="Close details"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <dl class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div>
          <dt class="text-2xs uppercase tracking-wider text-base-content/45">Due date</dt>

          <dd class="mt-0.5 text-sm">{Format.format_date(@obligation.due_date)}</dd>
        </div>

        <div>
          <dt class="text-2xs uppercase tracking-wider text-base-content/45">Status</dt>

          <dd class="mt-0.5 text-sm">{@obligation.status}</dd>
        </div>

        <div>
          <dt class="text-2xs uppercase tracking-wider text-base-content/45">Filed on</dt>

          <dd class="mt-0.5 text-sm">{Format.format_date(@obligation.filed_on)}</dd>
        </div>

        <div>
          <dt class="text-2xs uppercase tracking-wider text-base-content/45">Statutory rule</dt>

          <dd class="mt-0.5 text-sm">{rule(@obligation.type)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc """
  The dialog that adds or edits a task or reminder.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :kind, :string, required: true
  attr :editing?, :boolean, required: true

  def task_dialog(assigns) do
    ~H"""
    <div
      id="task-dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="task-dialog-title"
      class="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto p-4"
      phx-window-keydown="cancel_task"
      phx-key="escape"
    >
      <div class="fixed inset-0 bg-base-content/30 backdrop-blur-sm" phx-click="cancel_task" />

      <div class="relative w-full max-w-md rounded-box border border-base-300 bg-base-100 p-5 shadow-xl">
        <div class="mb-4 flex items-start justify-between gap-3">
          <div>
            <h2 id="task-dialog-title" class="text-sm font-semibold tracking-tight">
              {if @editing?, do: "Edit", else: "Add"} {@kind}
            </h2>

            <p class="mt-0.5 text-xs text-base-content/60">
              It appears with your filing deadlines and in any connected calendar.
            </p>
          </div>

          <button
            type="button"
            phx-click="cancel_task"
            class="flex size-7 items-center justify-center rounded-field text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <.form for={@form} id="task-form" phx-change="validate_task" phx-submit="save_task">
          <div class="space-y-3">
            <.input
              field={@form[:title]}
              type="text"
              label="Title"
              maxlength="200"
              phx-debounce="300"
              phx-mounted={JS.focus()}
              required
            />
            <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <.input field={@form[:due_date]} type="date" label="Due date" required />
              <.input
                field={@form[:category]}
                type="select"
                label="Category"
                options={Compliance.task_categories()}
              />
            </div>
            <.input
              field={@form[:remind_days_before]}
              type="number"
              label="Remind me this many days before"
              min="0"
              max="365"
            />
            <.input
              field={@form[:notes]}
              type="textarea"
              label="Notes"
              maxlength="2000"
              phx-debounce="300"
            />
          </div>

          <div class="mt-4 flex justify-end gap-2">
            <button
              id="task-cancel"
              type="button"
              phx-click="cancel_task"
              class={secondary_button_class()}
            >
              Cancel
            </button>
            <button
              id="task-save"
              type="submit"
              phx-disable-with="Saving..."
              class={action_button_class()}
            >
              {if @editing?, do: "Save changes", else: "Add #{@kind}"}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # Screen-reader label for a cell.
  defp day_label(%{obligations: []} = cell), do: Format.format_date(cell.date)

  defp day_label(cell) do
    due = Enum.map_join(cell.obligations, ", ", & &1.type)
    "#{Format.format_date(cell.date)} — #{due} due"
  end

  defp rule("GSTR-1"), do: "11th of the following month"
  defp rule("GSTR-3B"), do: "20th of the following month"
  defp rule("CMP-08"), do: "18th after quarter end"
  defp rule("GSTR-9"), do: "31 December after year end"
  defp rule("GSTR-9C"), do: "31 December after year end"
  defp rule(_type), do: "—"
end
