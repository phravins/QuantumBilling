defmodule QuantumBillingWeb.ComplianceTasksLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Audit
  alias QuantumBilling.Compliance
  alias QuantumBilling.Notifications

  setup :register_and_log_in_user

  setup %{scope: scope} do
    %{scope: %{scope | business: QuantumBilling.Businesses.default!()}}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Renew trade licence",
        "due_date" => Date.to_iso8601(Date.add(Date.utc_today(), 30)),
        "category" => "other",
        "remind_days_before" => "3",
        "notes" => "Municipal office"
      },
      overrides
    )
  end

  defp open_form(view, button) do
    view |> element(button) |> render_click()
    assert has_element?(view, "#task-form")
  end

  defp add_task(conn, overrides \\ %{}) do
    {:ok, view, _html} = live(conn, ~p"/compliance")
    open_form(view, "#add-task")
    view |> form("#task-form", task: attrs(overrides)) |> render_submit()
    view
  end

  defp stored(scope), do: Compliance.list_tasks(scope)

  describe "adding" do
    test "a task appears in the table with its controls", %{conn: conn, scope: scope} do
      view = add_task(conn)

      assert [task] = stored(scope)
      assert task.kind == "task"
      assert task.created_by_id == scope.user.id
      refute has_element?(view, "#task-form")
      assert has_element?(view, "#task-#{task.id}")
      assert has_element?(view, "#task-complete-#{task.id}")
      assert has_element?(view, "#task-edit-#{task.id}")
      assert has_element?(view, "#task-delete-#{task.id}")
    end

    test "a reminder is stored as a reminder", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/compliance")
      open_form(view, "#add-reminder")
      view |> form("#task-form", task: attrs()) |> render_submit()

      assert [%{kind: "reminder"}] = stored(scope)
    end

    test "a blank title is refused and the form stays open", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/compliance")
      open_form(view, "#add-task")

      view |> form("#task-form", task: attrs(%{"title" => "  "})) |> render_submit()

      assert stored(scope) == []
      assert has_element?(view, "#task-form")
    end

    test "the form cannot choose the author or status", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/compliance")
      open_form(view, "#add-task")

      render_submit(view, "save_task", %{
        "task" => Map.merge(attrs(), %{"status" => "done", "created_by_id" => "999999"})
      })

      assert [%{status: "open"} = task] = stored(scope)
      assert task.created_by_id == scope.user.id
    end

    test "cancel closes the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")
      open_form(view, "#add-task")

      view |> element("#task-cancel") |> render_click()

      refute has_element?(view, "#task-form")
    end

    test "a save with no form open does nothing", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      render_submit(view, "save_task", %{"task" => attrs()})

      assert stored(scope) == []
    end
  end

  describe "changing" do
    test "edit, complete, reopen and delete", %{conn: conn, scope: scope} do
      view = add_task(conn)
      [task] = stored(scope)

      view |> element("#task-edit-#{task.id}") |> render_click()
      view |> form("#task-form", task: %{"title" => "Renew licence"}) |> render_submit()
      assert [%{title: "Renew licence"}] = stored(scope)

      view |> element("#task-complete-#{task.id}") |> render_click()
      assert [%{status: "done", completed_at: %DateTime{}}] = stored(scope)
      assert has_element?(view, "#task-reopen-#{task.id}")

      view |> element("#task-reopen-#{task.id}") |> render_click()
      assert [%{status: "open", completed_at: nil}] = stored(scope)

      view |> element("#task-delete-#{task.id}") |> render_click()
      assert stored(scope) == []
      refute has_element?(view, "#task-#{task.id}")
    end

    test "each change reaches the audit trail", %{conn: conn, scope: scope} do
      view = add_task(conn)
      [task] = stored(scope)

      view |> element("#task-complete-#{task.id}") |> render_click()

      actions = Audit.actions()
      assert "create_compliance_task" in actions
      assert "complete_compliance_task" in actions
    end

    test "forged ids find nothing and leave the page up", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      for id <- ["999999", "not-a-number", "99999999999999999999999", "-1"],
          event <- ~w(edit_task complete_task reopen_task delete_task) do
        render_click(view, event, %{"id" => id})
      end

      assert has_element?(view, "#add-task")
    end

    test "a forged kind opens nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compliance")

      render_click(view, "new_task", %{"kind" => "admin"})

      refute has_element?(view, "#task-form")
    end
  end

  describe "appearing with the deadlines" do
    test "no GSTIN, but a task: the table shows it, not the empty state", %{conn: conn} do
      view = add_task(conn)

      refute render(view) =~ "No GST registration on file"
    end

    test "the category tab narrows tasks too", %{conn: conn, scope: scope} do
      view = add_task(conn, %{"category" => "payments"})
      [task] = stored(scope)

      view
      |> element("button[phx-click=filter_category][phx-value-category=returns]")
      |> render_click()

      refute has_element?(view, "#task-#{task.id}")

      view
      |> element("button[phx-click=filter_category][phx-value-category=payments]")
      |> render_click()

      assert has_element?(view, "#task-#{task.id}")
    end

    test "a calendar day with a task can be selected", %{conn: conn, scope: scope} do
      due = Date.utc_today()
      view = add_task(conn, %{"due_date" => Date.to_iso8601(due)})
      [task] = stored(scope)

      view |> element("button[phx-value-date='#{due}']") |> render_click()

      assert has_element?(view, "#task-#{task.id}")
    end

    test "a task named after a return gets no export link", %{conn: conn, scope: scope} do
      view = add_task(conn, %{"title" => "GSTR-1"})
      [task] = stored(scope)

      refute has_element?(view, "#task-#{task.id} a[href*='gstr1']")
    end

    test "a title is shown as text, not markup", %{conn: conn} do
      view = add_task(conn, %{"title" => "<img src=x onerror=alert(1)>"})

      refute has_element?(view, "img[onerror]")
    end
  end

  describe "reminders" do
    test "one inside its window is announced straight away, and once", %{conn: conn, scope: scope} do
      add_task(conn, %{"due_date" => Date.to_iso8601(Date.utc_today())})

      assert [%{title: title}] = Notifications.recent(50)
      assert title =~ "due today"
      assert [%{reminded_at: %DateTime{}}] = stored(scope)

      assert Compliance.remind_due_tasks(Date.utc_today()) == 0
      assert length(Notifications.recent(50)) == 1
    end

    test "one outside its window waits", %{conn: conn, scope: scope} do
      add_task(conn)

      assert Notifications.recent(50) == []

      [task] = stored(scope)
      assert Compliance.remind_due_tasks(Date.add(task.due_date, -3)) == 1
    end

    test "a finished task is not announced", %{conn: conn, scope: scope} do
      view = add_task(conn)
      [task] = stored(scope)

      view |> element("#task-complete-#{task.id}") |> render_click()

      assert Compliance.remind_due_tasks(task.due_date) == 0
    end

    test "moving the date allows a new reminder", %{conn: conn, scope: scope} do
      add_task(conn, %{"due_date" => Date.to_iso8601(Date.utc_today())})
      [task] = stored(scope)

      next_month = Date.add(Date.utc_today(), 30)

      {:ok, moved} =
        Compliance.update_task(scope, task, %{"due_date" => Date.to_iso8601(next_month)})

      assert moved.reminded_at == nil
      assert Compliance.remind_due_tasks(next_month) == 1
    end
  end
end
