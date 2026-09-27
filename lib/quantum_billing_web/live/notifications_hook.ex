defmodule QuantumBillingWeb.NotificationsHook do
  @moduledoc """
  Puts the notification bell on every authenticated page and keeps it live.

  ## Why a hook rather than a component

  The bell lives in `Layouts.app`, which every signed-in page draws, and it has
  to do three things no function component can: subscribe to a topic, reload
  itself when something arrives on it, and handle its own clicks. Attaching
  those to the socket in an `on_mount` hook gives the bell to every page at
  once, without twenty LiveViews growing a `handle_info` clause for a message
  they have no interest in — and, as `UserAuth.watch_own_account/1` already
  found for the sidebar, a LiveView that receives a message it has no clause
  for does not ignore it, it crashes.

  `attach_hook/4` on `:handle_event` is what lets the panel's own buttons work
  from here. The hooks halt only on the messages and events that are theirs;
  everything else continues to the page, untouched.

  ## What it assigns

    * `@notifications` — the newest few, newest first
    * `@unread_count` — what the badge shows, and whether it shows at all

  A new notification is applied to both from the broadcast itself; anything
  else re-reads them from the database. The split is deliberate. An inserted
  row is always the newest and always unread, so prepending it and adding one
  to the badge is not an approximation — it is exactly what a re-read would
  return. Marking read is not: which rows it covers depends on the table, not
  on the fifteen this socket happens to be holding, so that one is answered by
  querying.

  It matters because of who publishes what. `:notification_created` comes from
  invoice writes, the payment webhook and the nightly workers, and reaches
  every open window in the business at once — re-reading there would turn one
  invoice into two queries per connected page, for a row the message already
  carried. `:notifications_read` comes from somebody clicking the bell, once.

  ## What this costs in tests

  Rendering the broadcast payload rather than re-reading means the bell is not
  inside the Ecto sandbox: PubSub is global, so in an `async: true` test a
  notification written by a *different* test running at the same moment is
  delivered here and drawn into this socket's panel. It cannot leak between
  users in production — there is one organisation and every notification is
  addressed to all of it — but it does mean a LiveView assertion of the form
  `refute render(view) =~ "Some Client"` is no longer sound, because another
  test's invoice for a client of that name will put the string on the page.

  Assert against the element you mean — the row, the table, the card — rather
  than against the rendered document. `EWayBillsLiveTest` and `InvoicesLiveTest`
  both carry notes at the lines where this bit.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias QuantumBilling.Notifications
  alias QuantumBilling.Notifications.Notification

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Notifications.subscribe()

    socket =
      socket
      |> assign_feed()
      |> attach_hook(:notifications_feed, :handle_info, &handle_feed_info/2)
      |> attach_hook(:notifications_actions, :handle_event, &handle_feed_event/3)

    {:cont, socket}
  end

  # Patched in place rather than re-read: see the note on the module. The badge
  # is incremented rather than recounted because the row that just arrived is
  # unread by construction — nothing has had the chance to open it yet.
  defp handle_feed_info({:notification_created, %Notification{} = notification}, socket) do
    feed = Enum.take([notification | socket.assigns.notifications], Notifications.feed_limit())

    {:halt,
     socket
     |> assign(:notifications, feed)
     |> assign(:unread_count, socket.assigns.unread_count + 1)}
  end

  defp handle_feed_info({:notifications_read, _which}, socket) do
    {:halt, assign_feed(socket)}
  end

  defp handle_feed_info(_message, socket), do: {:cont, socket}

  # Marked read on the server and navigated from the server, rather than
  # letting the link carry both: a `<.link navigate>` with a `phx-click` on it
  # races its own navigation, and the notification you clicked is exactly the
  # one that would sometimes stay unread.
  defp handle_feed_event("open_notification", %{"id" => id}, socket) do
    notification = Notifications.get_notification(id)
    _ = Notifications.mark_read(id)

    socket = assign_feed(socket)

    case notification do
      %{path: path} when is_binary(path) and path != "" ->
        {:halt, push_navigate(socket, to: path)}

      _nowhere_to_go ->
        {:halt, socket}
    end
  end

  defp handle_feed_event("mark_all_notifications_read", _params, socket) do
    Notifications.mark_all_read()
    {:halt, assign_feed(socket)}
  end

  defp handle_feed_event(_event, _params, socket), do: {:cont, socket}

  defp assign_feed(socket) do
    feed = Notifications.feed()

    socket
    |> assign(:notifications, feed.notifications)
    |> assign(:unread_count, feed.unread_count)
  end
end
