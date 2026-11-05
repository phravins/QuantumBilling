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

  ## Tasks added by hand

  `QuantumBilling.Compliance.Task` holds whatever the rules do not cover. A task
  becomes a row of the same shape as an obligation through `task_row/2`, with
  the record itself under `:task`, so the table, calendar and rail treat both
  alike. Only the rows carrying `:task` can be edited.
  """
  import Ecto.Query, warn: false

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit
  alias QuantumBilling.Calendars
  alias QuantumBilling.Compliance.ReminderEmail
  alias QuantumBilling.Compliance.Task
  alias QuantumBilling.Notifications
  alias QuantumBilling.Repo

  @max_id 9_223_372_036_854_775_807

  # Offsets for the organisation timezones on offer, none of which keeps
  # daylight saving. The app ships no timezone database, and a reminder at
  # "9:00" has to mean nine o'clock where the business is.
  @utc_offsets %{"Asia/Kolkata" => 19_800}

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

  @statuses ["All Status", "Filed", "Done", "Pending", "Overdue"]

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
        period_key: period_key(period),
        due_date: due_on(shift_months(period, 1), due_day)
      }
    end
  end

  @doc """
  A period as `MMYYYY`, which is how every GSTN payload identifies one.
  """
  def period_key(%Date{} = date) do
    String.pad_leading(to_string(date.month), 2, "0") <> to_string(date.year)
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
        period_key: period_key(to),
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
        period_key: period_key(shift_months(fy_start, 11)),
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

  # No filing records exist yet.
  defp filed_on(_obligation), do: nil

  @doc """
  Filing records for the current tenant.

  Returns `[]` until the filings table exists, which is why no obligation
  currently resolves to `"Filed"`.
  """
  def filings, do: []

  @doc """
  The obligations this tenant is actually tracking.

  `obligations/1` above is the statutory calendar in full: every return the Act
  defines, which is the same set of rows for every business in the country.
  What a particular business owes is narrower, and its own registration decides
  which rows to drop:

    * no GSTIN on file — nothing at all. An unregistered business files no GST
      returns, so the page stays empty rather than inventing deadlines for
      someone who owes none.
    * composition scheme — `CMP-08` quarterly, and no `GSTR-1` or `GSTR-3B`. A
      composition dealer does not file the monthly returns.
    * regular registration — `GSTR-1` and `GSTR-3B` monthly, and no `CMP-08`,
      which exists only for the composition scheme.

  Either way the annual returns apply. This is not invented data: once a GSTIN
  exists these dates are owed by statute whether or not the application has a
  record of them.

  Filing records are still the missing half — `filings/0` returns nothing — so
  every row resolves to `"Pending"` or `"Overdue"` on dates alone.
  """
  def tracked_obligations(today \\ Date.utc_today(), registration \\ nil) do
    if registered?(registration) do
      composition? = composition_scheme?(registration)

      today
      |> obligations()
      |> Enum.filter(&applies?(&1, composition?))
    else
      []
    end
  end

  defp applies?(%{type: "CMP-08"}, composition?), do: composition?

  defp applies?(%{type: type}, composition?) when type in ["GSTR-1", "GSTR-3B"],
    do: not composition?

  defp applies?(_annual_return, _composition?), do: true

  defp registered?(registration) do
    registration |> registration_field(:gstin) |> to_string() |> String.trim() != ""
  end

  defp composition_scheme?(registration),
    do: registration_field(registration, :composition_scheme) == true

  defp registration_field(nil, _key), do: nil
  defp registration_field(registration, key), do: Map.get(registration, key)

  @doc """
  Counts and percentages for the summary cards.

  Percentages are of the total, rounded to one decimal, and are `0.0` for an
  empty list rather than a division by zero.
  """
  def summary(obligations) do
    total = length(obligations)
    counts = Enum.frequencies_by(obligations, & &1.status)

    filed = Map.get(counts, "Filed", 0) + Map.get(counts, "Done", 0)
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
  The `limit` open obligations closest to `today`, in date order.

  Closest to today, not earliest: the statutory calendar covers a whole
  financial year and nothing is ever filed, so taking the earliest open rows
  filled the rail with last April every time — five deadlines months past,
  under a heading that says "Upcoming". Ranking by distance from today instead
  gives the window that actually needs attention, the last one or two that
  slipped and the next few coming up. A tie between an overdue date and a
  future one the same distance away goes to the overdue one.

  Each carries `days_until` — negative once the due date has passed, so the
  caller can distinguish "Due in 5 days" from "Overdue by 12 days".
  """
  def upcoming(obligations, today \\ Date.utc_today(), limit \\ 5) do
    obligations
    |> Enum.reject(&(&1.status in ["Filed", "Done"]))
    |> Enum.map(&Map.put(&1, :days_until, Date.diff(&1.due_date, today)))
    |> Enum.sort_by(&{abs(&1.days_until), &1.days_until})
    |> Enum.take(limit)
    |> Enum.sort_by(& &1.due_date, Date)
  end

  @doc """
  The obligations falling due on one date, in the order the table lists them.
  """
  def on_date(obligations, %Date{} = date) do
    Enum.filter(obligations, &(&1.due_date == date))
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

    # Back to the Sunday on or before the first of the month.
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

  @doc """
  The category a client names, or `:all` for one that does not exist.

  A closed list, so a forged value can neither create an atom nor crash the page.
  """
  def category_key("custom:" <> label) when byte_size(label) in 1..160, do: {:custom, label}

  def category_key(value) do
    Enum.find_value(@categories, :all, fn {key, _label} ->
      if to_string(key) == value, do: key
    end)
  end

  @doc "Human label for a category key."
  def category_label({:custom, label}), do: label

  def category_label(key) do
    {_key, label} = Enum.find(@categories, {key, to_string(key)}, fn {k, _l} -> k == key end)
    label
  end

  @doc """
  A category key as the string a tab sends back, the reverse of `category_key/1`.

  Custom ones carry their label — `"custom:Rent"` — rather than an atom.
  """
  def category_param({:custom, label}), do: "custom:" <> label
  def category_param(key), do: to_string(key)

  @doc """
  The filter tabs: the built-in categories, then one for each custom category
  among `rows`, in alphabetical order.
  """
  def category_tabs(rows) do
    custom =
      rows
      |> Enum.flat_map(fn
        %{category: {:custom, label} = key} -> [{key, label}]
        _row -> []
      end)
      |> Enum.uniq()
      |> Enum.sort_by(fn {_key, label} -> String.downcase(label) end)

    @categories ++ custom
  end

  @doc "The categories a task can be filed under, as select options."
  def task_categories do
    for({key, label} <- @categories, key != :all, do: {label, to_string(key)}) ++
      [{"Custom…", "custom"}]
  end

  @doc "How often a task can repeat, as select options."
  def repeat_options do
    [
      {"Does not repeat", "none"},
      {"Every week", "weekly"},
      {"Every month", "monthly"},
      {"Every quarter", "quarterly"},
      {"Every year", "yearly"}
    ]
  end

  @doc """
  The business's tasks, soonest first.

  Private ones are left out unless `scope`'s user wrote them.
  """
  def list_tasks(%Scope{} = scope) do
    in_business(scope, fn ->
      Task
      |> visible_to(scope)
      |> order_by([t], asc: t.due_date, asc: t.id)
      |> Repo.all()
    end)
  end

  defp visible_to(query, %Scope{user: %{id: user_id}}) do
    where(query, [t], not t.private or t.created_by_id == ^user_id)
  end

  defp visible_to(query, _scope), do: where(query, [t], not t.private)

  @doc """
  One task of this business, or `nil`.

  Takes the raw id from a client, so a forged or oversized one finds nothing
  rather than crashing the page. Somebody else's private task is not found
  either.
  """
  def get_task(%Scope{} = scope, raw_id) do
    case Ecto.Type.cast(:id, raw_id) do
      {:ok, id} when is_integer(id) and id > 0 and id <= @max_id ->
        in_business(scope, fn -> Task |> visible_to(scope) |> Repo.get(id) end)

      _invalid ->
        nil
    end
  end

  def change_task(%Task{} = task, attrs \\ %{}), do: Task.changeset(task, attrs)

  @doc "Adds a task or reminder. `kind` and the author are set here, not by the form."
  def create_task(%Scope{} = scope, kind, attrs) when kind in ["task", "reminder"] do
    in_business(scope, fn ->
      %Task{kind: kind, created_by_id: scope.user.id}
      |> Task.changeset(attrs)
      |> Repo.insert()
      |> after_change(scope, :create_compliance_task)
    end)
  end

  def update_task(%Scope{} = scope, %Task{} = task, attrs) do
    in_business(scope, fn ->
      task
      |> Task.changeset(authors_options_only(scope, task, attrs))
      |> Repo.update()
      |> after_change(scope, :update_compliance_task)
    end)
  end

  @doc """
  Marks a task done. A repeating one also gets its next occurrence, unless
  that is already there — reopening and completing again does not add a
  second.
  """
  def complete_task(%Scope{} = scope, %Task{} = task) do
    with {:ok, done} <-
           set_status(scope, task, "done", DateTime.utc_now(:second), :complete_compliance_task) do
      _ = schedule_next(scope, done)
      {:ok, done}
    end
  end

  @doc "When a task repeating as `repeat` next falls due after `date`; nil for none."
  def next_due_date(%Date{} = date, "weekly"), do: Date.add(date, 7)
  def next_due_date(%Date{} = date, "monthly"), do: shift_months(date, 1)
  def next_due_date(%Date{} = date, "quarterly"), do: shift_months(date, 3)
  def next_due_date(%Date{} = date, "yearly"), do: shift_months(date, 12)
  def next_due_date(_date, _repeat), do: nil

  defp schedule_next(scope, %Task{} = task) do
    with %Date{} = due_date <- next_due_date(task.due_date, task.repeat),
         false <- next_exists?(scope, task, due_date) do
      in_business(scope, fn ->
        %Task{
          kind: task.kind,
          created_by_id: task.created_by_id,
          title: task.title,
          notes: task.notes,
          category: task.category,
          custom_category: task.custom_category,
          due_date: due_date,
          remind_days_before: task.remind_days_before,
          repeat: task.repeat,
          private: task.private,
          remind_at: task.remind_at,
          email_reminder: task.email_reminder
        }
        |> Repo.insert()
        |> after_change(scope, :create_compliance_task)
      end)
    end
  end

  defp next_exists?(scope, task, due_date) do
    in_business(scope, fn ->
      Repo.exists?(
        from t in Task,
          where:
            t.title == ^task.title and t.kind == ^task.kind and t.due_date == ^due_date and
              t.id != ^task.id
      )
    end)
  end

  # Who a private task is hidden from, and who gets its email, is its author's
  # call; a teammate editing a shared task cannot hide it or mail the author.
  defp authors_options_only(%Scope{user: %{id: id}}, %Task{created_by_id: id}, attrs), do: attrs

  defp authors_options_only(_scope, _task, attrs) when is_map(attrs) do
    Map.drop(attrs, ["private", "email_reminder", :private, :email_reminder])
  end

  def reopen_task(%Scope{} = scope, %Task{} = task) do
    set_status(scope, task, "open", nil, :reopen_compliance_task)
  end

  def delete_task(%Scope{} = scope, %Task{} = task) do
    in_business(scope, fn ->
      task
      |> Repo.delete()
      |> after_change(scope, :delete_compliance_task)
    end)
  end

  defp set_status(scope, task, status, completed_at, action) do
    in_business(scope, fn ->
      task
      |> Ecto.Changeset.change(status: status, completed_at: completed_at)
      |> Repo.update()
      |> after_change(scope, action)
    end)
  end

  defp after_change({:ok, task} = result, scope, action) do
    Audit.log_event(action, "ComplianceTask", task.id,
      user_id: scope.user.id,
      details: %{title: task.title, due_date: task.due_date}
    )

    # A task already inside its window should not wait for the next sweep.
    remind_due_tasks(DateTime.utc_now())
    _ = Calendars.enqueue_sync()

    result
  end

  defp after_change(error, _scope, _action), do: error

  defp in_business(%Scope{business: business}, fun), do: Repo.with_business(business, fun)

  @doc "A task as a row of the same shape as an obligation."
  def task_row(%Task{} = task, %Date{} = today) do
    %{
      type: task.title,
      subtitle: if(task.kind == "reminder", do: "Reminder", else: "Task"),
      category: task_category(task),
      period_label: Calendar.strftime(task.due_date, "%b %Y"),
      period_key: nil,
      due_date: task.due_date,
      status: task_status(task, today),
      filed_on: task.completed_at && DateTime.to_date(task.completed_at),
      task: task
    }
  end

  defp task_category(%Task{category: "custom", custom_category: label})
       when is_binary(label) and label != "",
       do: {:custom, label}

  defp task_category(%Task{category: category}), do: category_key(category)

  defp task_status(%Task{status: "done"}, _today), do: "Done"

  defp task_status(%Task{due_date: due_date}, today) do
    if Date.compare(due_date, today) == :lt, do: "Overdue", else: "Pending"
  end

  @doc """
  Posts to the feed, once, every open task inside its reminder window.

  Given a `DateTime`, a task with a time of day waits until that time on its
  reminder day, in the organisation's timezone. Given a `Date`, the whole day
  counts — which is what a test, or a run for a past day, means.

  A private task's notification is addressed to its author alone, and a task
  with `email_reminder` also queues an email to its author.

  Returns how many were written. Runs inside the current business.
  """
  def remind_due_tasks(%Date{} = today), do: remind_tasks(today, nil)

  def remind_due_tasks(%DateTime{} = now) do
    local = local_time(now)
    remind_tasks(NaiveDateTime.to_date(local), NaiveDateTime.to_time(local))
  end

  @doc "`now` as wall-clock time where the business is."
  def local_time(%DateTime{} = now, timezone \\ nil) do
    timezone = timezone || organization_timezone()
    offset = Map.get(@utc_offsets, timezone, 0)

    now
    |> DateTime.add(offset, :second)
    |> DateTime.to_naive()
  end

  defp organization_timezone do
    case QuantumBilling.Settings.get_organization() do
      %{timezone: timezone} when is_binary(timezone) -> timezone
      _none -> nil
    end
  end

  defp remind_tasks(today, time) do
    Task
    |> where([t], t.status == "open" and is_nil(t.reminded_at))
    |> Repo.all()
    |> Enum.filter(&reminder_due?(&1, today, time))
    |> Enum.map(&announce_task(&1, today))
    |> Enum.count(&match?({:ok, %{}}, &1))
  end

  @doc """
  Whether `task`'s reminder is due on `today` at `time` (nil for "any time that
  day").
  """
  def reminder_due?(%Task{} = task, %Date{} = today, time) do
    remind_on = Date.add(task.due_date, -task.remind_days_before)

    case Date.compare(today, remind_on) do
      :lt -> false
      :gt -> true
      :eq -> is_nil(time) or is_nil(task.remind_at) or Time.compare(time, task.remind_at) != :lt
    end
  end

  defp announce_task(%Task{} = task, today) do
    days_until = Date.diff(task.due_date, today)

    result =
      Notifications.notify(%{
        kind: "compliance",
        severity: if(days_until < 0, do: "error", else: "warning"),
        title: "#{task.title} #{due_phrase(days_until)}",
        body: "Due #{Calendar.strftime(task.due_date, "%d %b %Y")}",
        path: "/compliance",
        recipient_id: if(task.private, do: task.created_by_id),
        dedupe_key: "compliance_task:#{task.id}:#{task.due_date}"
      })

    with {:ok, _written_or_duplicate} <- result do
      task
      |> Ecto.Changeset.change(reminded_at: DateTime.utc_now(:second))
      |> Repo.update!()
    end

    # Only with a fresh notification, so a duplicate never mails twice.
    with {:ok, %{}} <- result, true <- task.email_reminder do
      _ = ReminderEmail.deliver_async(task, due_phrase(days_until))
    end

    result
  end

  defp due_phrase(0), do: "is due today"
  defp due_phrase(1), do: "is due tomorrow"
  defp due_phrase(days) when days < 0, do: "is overdue"
  defp due_phrase(days), do: "is due in #{days} days"
end
