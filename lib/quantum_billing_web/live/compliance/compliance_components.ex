defmodule QuantumBillingWeb.ComplianceComponents do
  @moduledoc """
  Building blocks for the Compliance page: the category tabs, the month
  calendar and the upcoming-due-dates rail.

  Colour here is confined to status — the pills and the calendar's day markers —
  which is the one place `QuantumBillingWeb.SharedComponents.status_badge/1`
  already sanctions it. Everything else stays monochrome.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]
  import QuantumBillingWeb.DashboardComponents, only: [compliance_date_badge: 1]

  alias QuantumBillingWeb.Format

  @doc """
  Renders the All / Returns / Payments / Other Compliances tab row.
  """
  attr :categories, :list, required: true
  attr :active, :atom, required: true

  def tabs(assigns) do
    ~H"""
    <div class="-mb-px flex items-center gap-6 border-b border-base-300">
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
      />
      <div class="min-w-0 flex-1">
        <p class="truncate text-sm font-medium">
          {@obligation.type} - {@obligation.period_label}
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

  # Written out in full rather than interpolated: Tailwind scans source text,
  # so a class built from a variable is never emitted.
  defp status_tone("Filed"), do: "border-emerald-200 bg-emerald-50 text-emerald-700"
  defp status_tone("Pending"), do: "border-amber-200 bg-amber-50 text-amber-700"
  defp status_tone("Overdue"), do: "border-rose-200 bg-rose-50 text-rose-700"
  defp status_tone(_other), do: "border-base-300 bg-base-200 text-base-content/60"

  defp dot_tone("Filed"), do: "bg-emerald-500"
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
        
        <div :for={cell <- List.flatten(@weeks)} class="flex flex-col items-center gap-0.5 py-0.5">
          <span class={[
            "flex size-7 items-center justify-center rounded-full text-xs",
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
              title={"#{obligation.type} — #{obligation.period_label}"}
            />
          </span>
        </div>
      </div>
      
      <div class="mt-3 flex items-center justify-center gap-4 border-t border-base-300 pt-3">
        <span
          :for={status <- ~w(Filed Pending Overdue)}
          class="flex items-center gap-1.5 text-xs text-base-content/60"
        >
          <span class={["size-2 rounded-full", dot_tone(status)]} />{status}
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
      <div class="flex items-start justify-between gap-4">
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

  defp rule("GSTR-1"), do: "11th of the following month"
  defp rule("GSTR-3B"), do: "20th of the following month"
  defp rule("CMP-08"), do: "18th after quarter end"
  defp rule("GSTR-9"), do: "31 December after year end"
  defp rule("GSTR-9C"), do: "31 December after year end"
  defp rule(_type), do: "—"
end
