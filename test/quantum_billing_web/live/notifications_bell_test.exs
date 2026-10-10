defmodule QuantumBillingWeb.NotificationsBellTest do
  @moduledoc """
  The bell in the header, which `QuantumBillingWeb.NotificationsHook` attaches to
  every authenticated page.

  Mounted on `/clients` rather than on a page of its own: the bell has no route,
  it is drawn by `Layouts.app`, and the point of the hook is that any page in the
  authenticated `live_session` gets it. `/clients` is the cheapest of them.

  `async: false`, so the sandbox is shared and the LiveView process can read the
  rows this test inserts — without that the feed would mount empty every time and
  the assertions would all be about nothing.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Notifications

  setup :register_and_log_in_user

  defp notify(over \\ %{}) do
    {:ok, notification} =
      Notifications.notify(
        Map.merge(
          %{
            kind: "invoice",
            title: "Invoice INV-0001 created",
            body: "V2V Technologies · ₹59,000",
            path: "/invoices"
          },
          over
        )
      )

    notification
  end

  describe "an empty feed" do
    test "says so rather than showing an empty box", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      assert has_element?(view, "#notifications-bell")
      assert has_element?(view, "#notifications-panel", "Nothing new")
    end

    test "offers nothing to mark read and reports none unread", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      refute has_element?(view, "#notifications-mark-all")
      assert has_element?(view, ~s(#notifications-bell[aria-label="Notifications, none unread"]))
    end
  end

  describe "a feed with notifications" do
    test "renders the stored notification, title and body", %{conn: conn} do
      notification = notify()

      {:ok, view, _html} = live(conn, ~p"/clients")

      assert has_element?(view, "#notification-#{notification.id}", "Invoice INV-0001 created")
      assert has_element?(view, "#notification-#{notification.id}", "V2V Technologies")
      refute has_element?(view, "#notifications-panel", "Nothing new")
    end

    test "counts the unread ones in the label", %{conn: conn} do
      notify()
      notify(%{dedupe_key: nil, title: "Payment received"})

      {:ok, view, _html} = live(conn, ~p"/clients")

      assert has_element?(view, ~s(#notifications-bell[aria-label="Notifications, 2 unread"]))
      assert has_element?(view, "#notifications-mark-all")
    end

    test "newest first", %{conn: conn} do
      older = notify(%{title: "The older one"})
      newer = notify(%{title: "The newer one"})

      {:ok, view, _html} = live(conn, ~p"/clients")

      # `query/2` searches descendants; `filter/2` only narrows the nodes it is given.
      ids =
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#notifications-panel li")
        |> LazyHTML.attribute("id")

      assert ids == ["notification-#{newer.id}", "notification-#{older.id}"]
    end
  end

  # Updated over PubSub, with no reload or polling.
  describe "in real time" do
    test "a notification written elsewhere arrives without a reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      assert has_element?(view, "#notifications-panel", "Nothing new")

      notification = notify()

      assert has_element?(view, "#notification-#{notification.id}")
      assert has_element?(view, ~s(#notifications-bell[aria-label="Notifications, 1 unread"]))
    end

    # The live feed applies the same cap as `Notifications.recent/1`.
    test "the feed stays capped however many arrive", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      limit = Notifications.feed_limit()
      sent = for n <- 1..(limit + 3), do: notify(%{title: "Notice #{n}"})

      rows =
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#notifications-panel li")
        |> LazyHTML.attribute("id")

      assert length(rows) == limit

      # By id: "Notice 1" is a substring of "Notice 10".
      assert has_element?(view, "#notification-#{List.last(sent).id}")
      refute has_element?(view, "#notification-#{List.first(sent).id}")

      # The badge still counts every one of them, not just the ones on screen.
      assert has_element?(
               view,
               ~s(#notifications-bell[aria-label="Notifications, #{limit + 3} unread"])
             )
    end

    test "one read in another window stops being unread here", %{conn: conn} do
      notification = notify()

      {:ok, view, _html} = live(conn, ~p"/clients")
      assert has_element?(view, ~s(#notifications-bell[aria-label="Notifications, 1 unread"]))

      Notifications.mark_read(notification.id)

      assert has_element?(view, ~s(#notifications-bell[aria-label="Notifications, none unread"]))
      # Still listed — read, not deleted.
      assert has_element?(view, "#notification-#{notification.id}")
    end
  end

  describe "clicking a notification" do
    test "marks it read and follows its path", %{conn: conn} do
      notification = notify()

      {:ok, view, _html} = live(conn, ~p"/clients")

      assert {:error, {:live_redirect, %{to: "/invoices"}}} =
               view |> element("#notification-#{notification.id} button") |> render_click()

      assert Notifications.get_notification(notification.id).read_at
    end

    test "one with nowhere to go is still marked read", %{conn: conn} do
      notification = notify(%{path: nil})

      {:ok, view, _html} = live(conn, ~p"/clients")

      view |> element("#notification-#{notification.id} button") |> render_click()

      assert Notifications.get_notification(notification.id).read_at
      assert has_element?(view, ~s(#notifications-bell[aria-label="Notifications, none unread"]))
    end

    test "a stale id does not take the page down with it", %{conn: conn} do
      notify()

      {:ok, view, _html} = live(conn, ~p"/clients")

      render_click(view, "open_notification", %{"id" => "0"})

      assert has_element?(view, "#notifications-bell")
    end
  end

  test "mark all read empties the count but keeps the list", %{conn: conn} do
    first = notify()
    second = notify(%{dedupe_key: nil, title: "Payment received"})

    {:ok, view, _html} = live(conn, ~p"/clients")

    view |> element("#notifications-mark-all") |> render_click()

    assert has_element?(view, ~s(#notifications-bell[aria-label="Notifications, none unread"]))
    refute has_element?(view, "#notifications-mark-all")
    assert has_element?(view, "#notification-#{first.id}")
    assert has_element?(view, "#notification-#{second.id}")
  end

  test "the bell is not drawn for a visitor who is not signed in" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/clients")
  end
end
