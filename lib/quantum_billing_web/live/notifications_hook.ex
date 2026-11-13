defmodule QuantumBillingWeb.NotificationsHook do
  @moduledoc """
  `on_mount` hook for the notification bell: subscribes to the business feed
  and assigns `@notifications` (newest first) and `@unread_count`.

  PubSub is shared in async tests, so assert on specific elements.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias QuantumBilling.Notifications
  alias QuantumBilling.Notifications.Notification

  # Pages before a business is chosen get an empty bell.
  def on_mount(:default, _params, _session, socket) do
    if QuantumBilling.Repo.business() do
      mount_feed(socket)
    else
      {:cont, assign(socket, notifications: [], unread_count: 0)}
    end
  end

  defp mount_feed(socket) do
    if connected?(socket), do: Notifications.subscribe()

    socket =
      socket
      |> assign_feed()
      |> attach_hook(:notifications_feed, :handle_info, &handle_feed_info/2)
      |> attach_hook(:notifications_actions, :handle_event, &handle_feed_event/3)

    {:cont, socket}
  end

  # Patched in place; a new row is unread. Rows addressed to someone else are skipped.
  defp handle_feed_info({:notification_created, %Notification{} = notification}, socket) do
    if Notifications.visible?(notification, viewer_id(socket)) do
      prepend(socket, notification)
    else
      {:halt, socket}
    end
  end

  defp handle_feed_info({:notifications_read, _which}, socket) do
    {:halt, assign_feed(socket)}
  end

  defp handle_feed_info(_message, socket), do: {:cont, socket}

  # Subscribing comes before the feed is read, so a row created in between
  # arrives twice; a second copy would duplicate its DOM id and count.
  defp prepend(socket, %Notification{id: id} = notification) do
    if Enum.any?(socket.assigns.notifications, &(&1.id == id)) do
      {:halt, socket}
    else
      add_to_feed(socket, notification)
    end
  end

  defp add_to_feed(socket, notification) do
    feed = Enum.take([notification | socket.assigns.notifications], Notifications.feed_limit())

    {:halt,
     socket
     |> assign(:notifications, feed)
     |> assign(:unread_count, socket.assigns.unread_count + 1)}
  end

  # Marked read and navigated server-side; a link with phx-click races its navigation.
  defp handle_feed_event("open_notification", %{"id" => id}, socket) do
    notification = Notifications.get_notification(id, viewer_id(socket))
    _ = Notifications.mark_read(id, viewer_id(socket))

    socket = assign_feed(socket)

    case notification do
      %{path: path} when is_binary(path) and path != "" ->
        {:halt, push_navigate(socket, to: path)}

      _nowhere_to_go ->
        {:halt, socket}
    end
  end

  defp handle_feed_event("mark_all_notifications_read", _params, socket) do
    Notifications.mark_all_read(viewer_id(socket))
    {:halt, assign_feed(socket)}
  end

  defp handle_feed_event(_event, _params, socket), do: {:cont, socket}

  defp assign_feed(socket) do
    feed = Notifications.feed(viewer_id(socket))

    socket
    |> assign(:notifications, feed.notifications)
    |> assign(:unread_count, feed.unread_count)
  end

  defp viewer_id(%{assigns: %{current_scope: %{user: %{id: id}}}}), do: id
  defp viewer_id(_socket), do: nil
end
