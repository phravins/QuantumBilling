defmodule QuantumBilling.NotificationsTest do
  @moduledoc """
  The feed behind the bell.

  The interesting cases are not "does an insert insert" but the three things a
  notification has to get right to be trustworthy: it must never be written
  twice by a producer that runs twice, it must broadcast so an open window sees
  it, and pruning must never take one nobody has read.

  Every `assert_receive`/`refute_receive` below pins the row it is about — by id
  or by dedupe key — and never matches the bare message. The topic is global and
  PubSub is not inside the sandbox, so a notification written by any other test
  running at the same moment is delivered here too; a bare match would make
  these tests pass or fail on somebody else's work.
  """
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Events
  alias QuantumBilling.Notifications
  alias QuantumBilling.Notifications.Notification
  alias QuantumBilling.Repo

  defp attrs(overrides \\ %{}) do
    Map.merge(%{kind: "invoice", title: "Invoice INV-0001 created"}, overrides)
  end

  describe "notify/1" do
    test "writes a notification and returns it" do
      assert {:ok, notification} = Notifications.notify(attrs())
      assert notification.kind == "invoice"
      assert notification.severity == "info"
      assert is_nil(notification.read_at)
    end

    test "takes string keys as readily as atoms" do
      assert {:ok, notification} =
               Notifications.notify(%{"kind" => "payment", "title" => "Payment received"})

      assert notification.kind == "payment"
    end

    test "announces it to anyone subscribed" do
      Notifications.subscribe()

      {:ok, notification} = Notifications.notify(attrs())
      id = notification.id

      assert_receive {:notification_created, %Notification{id: ^id}}
    end

    test "refuses an unknown kind" do
      assert {:error, changeset} = Notifications.notify(attrs(%{kind: "gossip"}))
      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    test "refuses an unknown severity" do
      assert {:error, changeset} = Notifications.notify(attrs(%{severity: "catastrophe"}))
      assert %{severity: ["is invalid"]} = errors_on(changeset)
    end

    test "requires a title" do
      assert {:error, changeset} = Notifications.notify(%{kind: "system"})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "truncates a title rather than failing on it" do
      {:ok, notification} = Notifications.notify(attrs(%{title: String.duplicate("a", 500)}))

      assert String.length(notification.title) == 200
      assert String.ends_with?(notification.title, "…")
    end
  end

  describe "the dedupe key" do
    test "a second write with the same key is reported as a duplicate, not an error" do
      assert {:ok, %Notification{}} = Notifications.notify(attrs(%{dedupe_key: "invoice:1"}))
      assert {:ok, :duplicate} = Notifications.notify(attrs(%{dedupe_key: "invoice:1"}))

      assert Notifications.unread_count() == 1
    end

    test "a duplicate is not announced" do
      key = "invoice:announced-once"

      Notifications.subscribe()
      {:ok, _first} = Notifications.notify(attrs(%{dedupe_key: key}))
      assert_receive {:notification_created, %Notification{dedupe_key: ^key}}

      {:ok, :duplicate} = Notifications.notify(attrs(%{dedupe_key: key}))
      refute_receive {:notification_created, %Notification{dedupe_key: ^key}}
    end

    test "rows without a key do not collide with each other" do
      assert {:ok, %Notification{}} = Notifications.notify(attrs())
      assert {:ok, %Notification{}} = Notifications.notify(attrs())

      assert Notifications.unread_count() == 2
    end
  end

  describe "recent/1 and feed/1" do
    test "returns the newest first" do
      {:ok, _old} = Notifications.notify(attrs(%{title: "First"}))
      {:ok, _new} = Notifications.notify(attrs(%{title: "Second"}))

      assert ["Second", "First"] = Enum.map(Notifications.recent(), & &1.title)
    end

    test "is bounded by the limit" do
      for n <- 1..5, do: Notifications.notify(attrs(%{title: "Notice #{n}"}))

      assert length(Notifications.recent(3)) == 3
    end

    test "feed/1 carries the list and the unread count together" do
      {:ok, read} = Notifications.notify(attrs(%{title: "Seen"}))
      {:ok, _unread} = Notifications.notify(attrs(%{title: "Unseen"}))
      {:ok, _} = Notifications.mark_read(read.id)

      assert %{notifications: notifications, unread_count: 1} = Notifications.feed()
      assert length(notifications) == 2
    end
  end

  describe "get_notification/1" do
    test "finds one by integer or string id" do
      {:ok, notification} = Notifications.notify(attrs())

      assert Notifications.get_notification(notification.id).id == notification.id
      assert Notifications.get_notification(to_string(notification.id)).id == notification.id
    end

    test "returns nil for junk rather than raising" do
      assert is_nil(Notifications.get_notification("not-an-id"))
      assert is_nil(Notifications.get_notification(nil))
      assert is_nil(Notifications.get_notification(0))
    end
  end

  describe "mark_read/1" do
    test "stamps the time and announces it" do
      Notifications.subscribe()
      {:ok, notification} = Notifications.notify(attrs())
      id = notification.id
      assert_receive {:notification_created, %Notification{id: ^id}}

      assert {:ok, read} = Notifications.mark_read(id)
      refute is_nil(read.read_at)
      assert Notifications.unread_count() == 0

      assert_receive {:notifications_read, ^id}
    end

    test "leaves an already-read one alone" do
      {:ok, notification} = Notifications.notify(attrs())
      {:ok, first} = Notifications.mark_read(notification.id)
      {:ok, second} = Notifications.mark_read(notification.id)

      assert first.read_at == second.read_at
    end

    test "reports a missing id rather than raising" do
      assert {:error, :not_found} = Notifications.mark_read(0)
      assert {:error, :not_found} = Notifications.mark_read("nonsense")
    end
  end

  describe "mark_all_read/0" do
    test "clears the count and announces once" do
      Notifications.subscribe()
      for n <- 1..3, do: Notifications.notify(attrs(%{title: "Notice #{n}"}))

      assert Notifications.mark_all_read() == 3
      assert Notifications.unread_count() == 0

      assert_receive {:notifications_read, :all}
    end

    test "is a no-op when there is nothing unread" do
      assert Notifications.mark_all_read() == 0
    end
  end

  describe "prune/1" do
    test "deletes read rows past the window" do
      {:ok, old} = Notifications.notify(attrs(%{title: "Ancient"}))
      {:ok, _} = Notifications.mark_read(old.id)
      age(old, 120)

      assert Notifications.prune(90) == 1
      assert Notifications.recent() == []
    end

    test "keeps an unread row however old it is" do
      {:ok, old} = Notifications.notify(attrs(%{title: "Never opened"}))
      age(old, 400)

      assert Notifications.prune(90) == 0
      assert length(Notifications.recent()) == 1
    end

    test "keeps a read row inside the window" do
      {:ok, recent} = Notifications.notify(attrs())
      {:ok, _} = Notifications.mark_read(recent.id)

      assert Notifications.prune(90) == 0
    end
  end

  describe "the topic" do
    test "is the one Events publishes on" do
      assert Events.notifications_topic() == "notifications"
    end
  end

  # Backdates a row past the retention window. Written straight to the database
  # because `inserted_at` is not castable — which is the point of it.
  defp age(%Notification{} = notification, days) do
    then = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    notification
    |> Ecto.Changeset.change(%{inserted_at: DateTime.truncate(then, :second)})
    |> Repo.update!()
  end
end
