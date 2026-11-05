defmodule QuantumBillingWeb.ComplianceReminderOptionsTest do
  @moduledoc """
  The options a reminder of one's own carries: a category named by the user,
  repeating, "Only me", and a time of day with an email.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.AccountsFixtures
  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Compliance
  alias QuantumBilling.Compliance.Task
  alias QuantumBilling.Notifications

  setup :register_and_log_in_user

  setup %{scope: scope} do
    business = QuantumBilling.Businesses.default!()
    teammate = AccountsFixtures.user_fixture()

    %{
      scope: %{scope | business: business},
      teammate: teammate,
      teammate_scope: %{Scope.for_user(teammate) | business: business}
    }
  end

  # Far enough out that the reminder sent on save never fires by accident.
  defp due, do: Date.add(Date.utc_today(), 40)

  defp attrs(overrides) do
    Map.merge(
      %{
        "title" => "Pay shop rent",
        "due_date" => Date.to_iso8601(due()),
        "category" => "other",
        "remind_days_before" => "1",
        "repeat" => "none"
      },
      overrides
    )
  end

  defp create(scope, overrides \\ %{}) do
    {:ok, task} = Compliance.create_task(scope, "reminder", attrs(overrides))
    task
  end

  defp open_reminder_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/compliance")
    view |> element("#add-reminder") |> render_click()
    view
  end

  describe "a category of one's own" do
    test "the name field appears only for Custom", %{conn: conn} do
      view = open_reminder_form(conn)
      refute has_element?(view, "#task-custom-category")

      view |> form("#task-form", task: %{"category" => "custom"}) |> render_change()

      assert has_element?(view, "#task-custom-category input[name='task[custom_category]']")
    end

    test "is saved, labelled on the row and gets its own tab", %{conn: conn, scope: scope} do
      view = open_reminder_form(conn)
      view |> form("#task-form", task: %{"category" => "custom"}) |> render_change()

      view
      |> form("#task-form",
        task: attrs(%{"category" => "custom", "custom_category" => "  Rent  "})
      )
      |> render_submit()

      assert [%Task{category: "custom", custom_category: "Rent"} = task] =
               Compliance.list_tasks(scope)

      assert has_element?(view, "#task-category-#{task.id}", "Rent")
      assert has_element?(view, "#compliance-tabs button[phx-value-category='custom:Rent']")

      view
      |> element("#compliance-tabs button[phx-value-category='custom:Rent']")
      |> render_click()

      assert has_element?(view, "#task-#{task.id}")
      refute has_element?(view, "tr[id^='obligation-']")
    end

    test "needs a name", %{conn: conn, scope: scope} do
      view = open_reminder_form(conn)
      view |> form("#task-form", task: %{"category" => "custom"}) |> render_change()

      view
      |> form("#task-form", task: attrs(%{"category" => "custom", "custom_category" => ""}))
      |> render_submit()

      assert Compliance.list_tasks(scope) == []
      assert has_element?(view, "#task-form")
    end

    test "a forged tab value neither crashes nor creates an atom" do
      assert Compliance.category_key("custom:Anything at all") == {:custom, "Anything at all"}
      assert Compliance.category_key("custom:") == :all
      assert Compliance.category_key("no_such_category_#{System.unique_integer()}") == :all
    end

    test "switching back to a built-in category drops the name", %{scope: scope} do
      task = create(scope, %{"category" => "custom", "custom_category" => "Rent"})
      {:ok, task} = Compliance.update_task(scope, task, %{"category" => "payments"})

      assert task.custom_category == nil
    end
  end

  describe "repeat" do
    test "completing a monthly reminder adds next month's, once", %{scope: scope} do
      task = create(scope, %{"repeat" => "monthly"})

      {:ok, done} = Compliance.complete_task(scope, task)
      next_due = Compliance.shift_months(task.due_date, 1)

      assert [%{id: id, status: "done"}, %{due_date: ^next_due, status: "open"} = next] =
               Compliance.list_tasks(scope)

      assert id == task.id
      assert next.repeat == "monthly"
      assert next.created_by_id == scope.user.id

      {:ok, reopened} = Compliance.reopen_task(scope, done)
      {:ok, _done_again} = Compliance.complete_task(scope, reopened)

      assert length(Compliance.list_tasks(scope)) == 2
    end

    test "a task that does not repeat adds nothing", %{scope: scope} do
      task = create(scope)
      {:ok, _done} = Compliance.complete_task(scope, task)

      assert [_only] = Compliance.list_tasks(scope)
    end

    test "next due dates" do
      date = ~D[2027-01-31]

      assert Compliance.next_due_date(date, "weekly") == ~D[2027-02-07]
      assert Compliance.next_due_date(date, "monthly") == ~D[2027-02-28]
      assert Compliance.next_due_date(date, "quarterly") == ~D[2027-04-30]
      assert Compliance.next_due_date(date, "yearly") == ~D[2028-01-31]
      assert Compliance.next_due_date(date, "none") == nil
    end

    test "an unknown repeat is refused", %{scope: scope} do
      assert {:error, changeset} =
               Compliance.create_task(scope, "reminder", attrs(%{"repeat" => "hourly"}))

      assert {_message, _meta} = changeset.errors[:repeat]
    end
  end

  describe "only me" do
    test "the task is hidden from a teammate", %{
      conn: conn,
      scope: scope,
      teammate: teammate,
      teammate_scope: teammate_scope
    } do
      task = create(scope, %{"private" => "true"})

      assert [%{id: id}] = Compliance.list_tasks(scope)
      assert id == task.id
      assert Compliance.list_tasks(teammate_scope) == []
      assert Compliance.get_task(teammate_scope, task.id) == nil

      {:ok, view, _html} = live(conn, ~p"/compliance")
      assert has_element?(view, "#task-private-#{task.id}")

      {:ok, teammate_view, _html} =
        conn |> recycle() |> log_in_user(teammate) |> live(~p"/compliance")

      refute has_element?(teammate_view, "#task-#{task.id}")
    end

    test "its reminder is addressed to the author alone", %{
      scope: scope,
      teammate: teammate
    } do
      task = create(scope, %{"private" => "true"})
      assert Compliance.remind_due_tasks(Date.add(task.due_date, -1)) == 1

      assert [notification] =
               Enum.filter(
                 Notifications.recent(50, scope.user.id),
                 &(&1.title =~ "Pay shop rent")
               )

      assert notification.recipient_id == scope.user.id
      refute Enum.any?(Notifications.recent(50, teammate.id), &(&1.id == notification.id))
      refute Enum.any?(Notifications.recent(50), &(&1.id == notification.id))
      assert Notifications.get_notification(notification.id, teammate.id) == nil
      assert {:error, :not_found} = Notifications.mark_read(notification.id, teammate.id)
    end

    test "a shared task's reminder is everyone's", %{scope: scope, teammate: teammate} do
      task = create(scope)
      assert Compliance.remind_due_tasks(Date.add(task.due_date, -1)) == 1

      assert Enum.any?(Notifications.recent(50, teammate.id), &(&1.title =~ "Pay shop rent"))
    end

    test "a teammate editing a shared task cannot make it private", %{
      conn: conn,
      scope: scope,
      teammate: teammate,
      teammate_scope: teammate_scope
    } do
      task = create(scope)

      {:ok, updated} =
        Compliance.update_task(teammate_scope, task, %{"private" => "true", "title" => "Renamed"})

      assert updated.title == "Renamed"
      refute updated.private

      {:ok, view, _html} = conn |> recycle() |> log_in_user(teammate) |> live(~p"/compliance")
      view |> element("#task-edit-#{task.id}") |> render_click()
      assert has_element?(view, "#task-form")
      refute has_element?(view, "#task-delivery-options")
    end

    test "private tasks stay off the shared calendar", %{scope: scope} do
      shared = create(scope)
      hidden = create(scope, %{"private" => "true", "title" => "Doctor"})

      keys = Enum.map(QuantumBilling.Calendars.items(), & &1.key)

      assert "task:#{shared.id}" in keys
      refute "task:#{hidden.id}" in keys
    end
  end

  describe "time of day and email" do
    # 16:00 in India is 10:30 UTC.
    test "a reminder with a time waits for it, in the business's timezone", %{scope: scope} do
      task = create(scope, %{"remind_at" => "16:00"})
      assert task.remind_at == ~T[16:00:00]

      remind_on = Date.add(task.due_date, -1)

      assert Compliance.remind_due_tasks(DateTime.new!(remind_on, ~T[10:15:00], "Etc/UTC")) == 0
      assert Compliance.remind_due_tasks(DateTime.new!(remind_on, ~T[10:30:00], "Etc/UTC")) == 1
    end

    test "a reminder without a time goes out first thing on its day", %{scope: scope} do
      task = create(scope)
      remind_on = Date.add(task.due_date, -1)

      # 00:05 in India, still the day before in UTC.
      assert Compliance.remind_due_tasks(
               DateTime.new!(Date.add(remind_on, -1), ~T[18:35:00], "Etc/UTC")
             ) ==
               1
    end

    test "local time is the organisation's" do
      now = ~U[2027-03-01 20:00:00Z]

      assert Compliance.local_time(now, "Asia/Kolkata") == ~N[2027-03-02 01:30:00]
    end

    test "email me sends the reminder to the author", %{scope: scope} do
      task = create(scope, %{"email_reminder" => "true", "notes" => "Owner: Mr Rao"})

      assert Compliance.remind_due_tasks(Date.add(task.due_date, -1)) == 1

      # The fixture's own confirmation mail is in the mailbox too.
      assert_received {:email, %Swoosh.Email{subject: "Reminder: " <> _} = email}
      assert email.to == [{"", scope.user.email}]
      assert email.subject == "Reminder: Pay shop rent is due tomorrow"
      assert email.text_body =~ "Owner: Mr Rao"
    end

    test "no email unless asked for", %{scope: scope} do
      task = create(scope)
      assert Compliance.remind_due_tasks(Date.add(task.due_date, -1)) == 1

      refute_received {:email, %Swoosh.Email{subject: "Reminder: " <> _}}
    end

    test "the dialog offers the options to the author", %{conn: conn} do
      view = open_reminder_form(conn)

      assert has_element?(view, "#task-form select[name='task[repeat]']")
      assert has_element?(view, "#task-form input[type='time'][name='task[remind_at]']")
      assert has_element?(view, "#task-delivery-options input[name='task[private]']")
      assert has_element?(view, "#task-delivery-options input[name='task[email_reminder]']")
    end
  end
end
