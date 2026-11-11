defmodule QuantumBilling.Compliance do
  @moduledoc """
  The GST compliance calendar and hand-made tasks.

  Obligations (GSTR-1, GSTR-3B, CMP-08, GSTR-9, GSTR-9C) are generated from the
  statutory due dates, not stored. Filing records don't exist yet, so each
  resolves to "Pending" or "Overdue". Tasks from `Compliance.Task` become rows
  of the same shape via `task_row/2`.
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

  # Fixed offsets for the timezones on offer (none use daylight saving).
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

  @doc "The financial year (April to March) containing `date`, as `{first, last}`."
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

  @doc "Every obligation in the financial year containing `today`, by due date."
  def obligations(today \\ Date.utc_today()) do
    {fy_start, _fy_end} = financial_year(today)

    (monthly_obligations(fy_start) ++
       quarterly_obligations(fy_start) ++
       annual_obligations(fy_start))
    |> Enum.map(&resolve_status(&1, today))
    |> Enum.sort_by(& &1.due_date, Date)
  end

  # Twelve periods from April, each due on a fixed day of the next month.
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

  # Four quarters from April, each due on the 18th after the quarter.
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

  # Annual returns are due 31 December after the year closes.
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

  defp filed_on(_obligation), do: nil

  @doc "Filing records. Always `[]` until a filings table exists."
  def filings, do: []

  @doc """
  The obligations this business tracks, based on its registration.

  No GSTIN, or a VAT business: none. Composition: CMP-08 and annual returns.
  Regular: GSTR-1, GSTR-3B and annual returns.
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
    registration_field(registration, :tax_regime) != "vat" and
      registration |> registration_field(:gstin) |> to_string() |> String.trim() != ""
  end

  defp composition_scheme?(registration),
    do: registration_field(registration, :composition_scheme) == true

  defp registration_field(nil, _key), do: nil
  defp registration_field(registration, key), do: Map.get(registration, key)

  @doc "Counts and percentages for the summary cards."
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
  The `limit` open obligations closest to `today`, overdue first on ties.

  Each has `days_until`, negative once overdue.
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
  Filters by category and status. `:all` and "All Status" match everything.
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

  @doc "A month as whole Sunday-to-Saturday weeks of `%{date, in_month?, obligations}`."
  def calendar_weeks(year, month, obligations) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)

    by_date = Enum.group_by(obligations, & &1.due_date)

    grid_start = Date.add(first, -(Date.day_of_week(first, :sunday) - 1))
    grid_end = Date.add(last, 7 - Date.day_of_week(last, :sunday))

    grid_start
    |> Date.range(grid_end)
    |> Enum.map(fn date ->
      %{date: date, in_month?: date.month == month, obligations: Map.get(by_date, date, [])}
    end)
    |> Enum.chunk_every(7)
  end

  @doc "Moves `date` by `count` months, clamping the day to the month's length."
  def shift_months(%Date{} = date, count) do
    total = date.year * 12 + (date.month - 1) + count
    year = div(total, 12)
    month = rem(total, 12) + 1

    Date.new!(year, month, min(date.day, Date.days_in_month(Date.new!(year, month, 1))))
  end

  defp due_on(%Date{} = month, day), do: Date.new!(month.year, month.month, day)

  def categories, do: @categories
  def statuses, do: @statuses

  @doc "The category a client names, or `:all`. A closed list, so no atoms are created."
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
  A category key as a tab value; custom ones are `"custom:Label"`.
  """
  def category_param({:custom, label}), do: "custom:" <> label
  def category_param(key), do: to_string(key)

  @doc "The filter tabs: built-in categories, then custom ones from `rows`."
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

  @doc "The business's tasks, soonest first. Others' private tasks are hidden."
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

  @doc "One task by raw id, or `nil`. Bad ids and others' private tasks find nothing."
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

  @doc "Marks a task done. A repeating task gets its next occurrence once."
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

  # Only the author can change privacy and email settings.
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
  Posts every open task inside its reminder window to the feed, once.

  With a `DateTime`, timed tasks wait for their time in the business timezone;
  with a `Date` the whole day counts. Private reminders go to the author only.
  Returns the number written.
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

  @doc "Whether `task`'s reminder is due on `today` at `time` (nil means any time)."
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

    # Only for a new notification, so nothing is emailed twice.
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
