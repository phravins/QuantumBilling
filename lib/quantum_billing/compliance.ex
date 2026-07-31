defmodule QuantumBilling.Compliance do
  @moduledoc """
  The GST compliance calendar.

  Unlike the other pages, nothing here is invented: an obligation's due date is
  fixed by statute, so the whole schedule is *generated from the rules* rather
  than stored. The rules implemented are:

    * `GSTR-1`  — monthly return, due the 11th of the following month
    * `GSTR-3B` — monthly return, due the 20th of the following month
    * `CMP-08`  — composition-scheme payment statement, quarterly, due the 18th
      of the month following the quarter
    * `GSTR-9`  — annual return, due 31 December after the financial year ends
    * `GSTR-9C` — reconciliation statement, same due date as `GSTR-9`

  What is *not* derivable is whether a given tenant actually filed. That needs
  the multi-tenant schema, so `filings/0` returns nothing and every obligation
  resolves to `"Pending"` or `"Overdue"` on dates alone. Supplying filing
  records is the only change needed to make `"Filed"` appear.

  The Indian financial year runs 1 April – 31 March, which is why the year
  boundary is computed rather than taken from `Date.year/1`.

  Every function takes the reference date explicitly so callers — and tests —
  never depend on when they run.
  """

  @monthly [
    {"GSTR-1", "Monthly Return", :returns, 11},
    {"GSTR-3B", "Monthly Return", :returns, 20}
  ]

  @annual [
    {"GSTR-9", "Annual Return", :returns},
    {"GSTR-9C", "Reconciliation", :other}
  ]

  @categories [
    {:all, "All"},
    {:returns, "Returns"},
    {:payments, "Payments"},
    {:other, "Other Compliances"}
  ]

  @statuses ["All Status", "Filed", "Pending", "Overdue"]

  @doc """
  The financial year containing `date`, as `{first_day, last_day}`.

  April starts a new year, so January–March belong to the year before.
  """
  def financial_year(%Date{} = date) do
    start_year = if date.month >= 4, do: date.year, else: date.year - 1
    {Date.new!(start_year, 4, 1), Date.new!(start_year + 1, 3, 31)}
  end

  @doc """
  Label for a financial year, e.g. `"FY 2026-27"`.
  """
  def financial_year_label(%Date{} = date) do
    {from, _to} = financial_year(date)
    "FY #{from.year}-#{from.year |> Kernel.+(1) |> to_string() |> String.slice(2..3)}"
  end

  @doc """
  Every obligation falling in the financial year that contains `today`.

  Ordered by due date. Each entry is `%{type, subtitle, category, period_label,
  due_date, status, filed_on}`.
  """
  def obligations(today \\ Date.utc_today()) do
    {fy_start, _fy_end} = financial_year(today)

    (monthly_obligations(fy_start) ++
       quarterly_obligations(fy_start) ++
       annual_obligations(fy_start))
    |> Enum.map(&resolve_status(&1, today))
    |> Enum.sort_by(& &1.due_date, Date)
  end

  # Twelve periods from April, each due on a fixed day of the following month.
  defp monthly_obligations(fy_start) do
    for offset <- 0..11,
        {type, subtitle, category, due_day} <- @monthly do
      period = shift_months(fy_start, offset)

      %{
        type: type,
        subtitle: subtitle,
        category: category,
        period_label: Calendar.strftime(period, "%b %Y"),
        due_date: due_on(shift_months(period, 1), due_day)
      }
    end
  end

  # Four quarters from April, each due on the 18th of the month after the
  # quarter closes.
  defp quarterly_obligations(fy_start) do
    for quarter <- 0..3 do
      from = shift_months(fy_start, quarter * 3)
      to = shift_months(from, 2)

      %{
        type: "CMP-08",
        subtitle: "Composition Scheme",
        category: :payments,
        period_label: "#{Calendar.strftime(from, "%b")} - #{Calendar.strftime(to, "%b %Y")}",
        due_date: due_on(shift_months(to, 1), 18)
      }
    end
  end

  # Annual filings are due on 31 December following the close of the year.
  defp annual_obligations(fy_start) do
    label = financial_year_label(fy_start)

    for {type, subtitle, category} <- @annual do
      %{
        type: type,
        subtitle: subtitle,
        category: category,
        period_label: label,
        due_date: Date.new!(fy_start.year + 1, 12, 31)
      }
    end
  end

  defp resolve_status(obligation, today) do
    filed_on = filed_on(obligation)

    status =
      cond do
        filed_on != nil -> "Filed"
        Date.compare(obligation.due_date, today) == :lt -> "Overdue"
        true -> "Pending"
      end

    Map.merge(obligation, %{status: status, filed_on: filed_on})
  end

  # No filing records exist yet, so nothing is ever filed. When the schema
  # lands this looks the obligation up in `filings/0`.
  defp filed_on(_obligation), do: nil

  @doc """
  Filing records for the current tenant.

  Returns `[]` until the filings table exists, which is why no obligation
  currently resolves to `"Filed"`.
  """
  def filings, do: []

  @doc """
  Counts and percentages for the summary cards.

  Percentages are of the total, rounded to one decimal, and are `0.0` for an
  empty list rather than a division by zero.
  """
  def summary(obligations) do
    total = length(obligations)
    counts = Enum.frequencies_by(obligations, & &1.status)

    filed = Map.get(counts, "Filed", 0)
    pending = Map.get(counts, "Pending", 0)
    overdue = Map.get(counts, "Overdue", 0)

    %{
      total: total,
      filed: filed,
      pending: pending,
      overdue: overdue,
      filed_pct: percentage(filed, total),
      pending_pct: percentage(pending, total),
      overdue_pct: percentage(overdue, total)
    }
  end

  defp percentage(_count, 0), do: 0.0
  defp percentage(count, total), do: Float.round(count / total * 100, 1)

  @doc """
  The next `limit` obligations that are not yet filed, soonest first.

  Each carries `days_until` — negative once the due date has passed, so the
  caller can distinguish "Due in 5 days" from "Overdue by 12 days".
  """
  def upcoming(obligations, today \\ Date.utc_today(), limit \\ 5) do
    obligations
    |> Enum.reject(&(&1.status == "Filed"))
    |> Enum.sort_by(& &1.due_date, Date)
    |> Enum.take(limit)
    |> Enum.map(&Map.put(&1, :days_until, Date.diff(&1.due_date, today)))
  end

  @doc """
  Narrows obligations by category and status. `:all` and `"All Status"` match
  everything.
  """
  def filter(obligations, filters) do
    obligations
    |> Enum.filter(&matches_category?(&1, filters[:category]))
    |> Enum.filter(&matches_status?(&1, filters[:status]))
  end

  defp matches_category?(_obligation, nil), do: true
  defp matches_category?(_obligation, :all), do: true
  defp matches_category?(obligation, category), do: obligation.category == category

  defp matches_status?(_obligation, nil), do: true
  defp matches_status?(_obligation, "All Status"), do: true
  defp matches_status?(obligation, status), do: obligation.status == status

  @doc """
  A month laid out as whole weeks for the calendar grid.

  Always returns complete Sunday-to-Saturday rows, padded with the neighbouring
  months' days so the grid never has holes. Each cell is
  `%{date, in_month?, obligations}`.
  """
  def calendar_weeks(year, month, obligations) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)

    by_date = Enum.group_by(obligations, & &1.due_date)

    # Date.day_of_week/2 with :sunday gives 1 for Sunday, so subtracting one
    # lands the grid on the Sunday at or before the first of the month.
    grid_start = Date.add(first, -(Date.day_of_week(first, :sunday) - 1))
    grid_end = Date.add(last, 7 - Date.day_of_week(last, :sunday))

    grid_start
    |> Date.range(grid_end)
    |> Enum.map(fn date ->
      %{date: date, in_month?: date.month == month, obligations: Map.get(by_date, date, [])}
    end)
    |> Enum.chunk_every(7)
  end

  @doc """
  Moves `date` by `count` months, clamping the day to the target month's length
  so the 31st never rolls into the next month.
  """
  def shift_months(%Date{} = date, count) do
    total = date.year * 12 + (date.month - 1) + count
    year = div(total, 12)
    month = rem(total, 12) + 1

    Date.new!(year, month, min(date.day, Date.days_in_month(Date.new!(year, month, 1))))
  end

  defp due_on(%Date{} = month, day), do: Date.new!(month.year, month.month, day)

  def categories, do: @categories
  def statuses, do: @statuses

  @doc "Human label for a category key."
  def category_label(key) do
    {_key, label} = Enum.find(@categories, {key, to_string(key)}, fn {k, _l} -> k == key end)
    label
  end
end
