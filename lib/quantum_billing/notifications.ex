defmodule QuantumBilling.Notifications do
  @moduledoc """
  The in-app notification feed and its real-time delivery.

  `notify/1` writes a row and then broadcasts it; failures are ignored so a
  notification never breaks the caller. The feed and its read state belong to
  the business, except rows with a `recipient_id`, which only that user sees.
  A `dedupe_key` (e.g. `"compliance:GSTR-1:2027-02-11"`) makes repeats return
  `{:ok, :duplicate}`, so retrying producers are safe.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Events
  alias QuantumBilling.Notifications.Notification
  alias QuantumBilling.Repo

  @feed_limit 15

  @doc """
  Subscribes the caller to the feed: `{:notification_created, n}` and `{:notifications_read, :all | id}`.
  """
  def subscribe, do: Events.subscribe(Events.notifications_topic())

  @doc """
  Records a notification and broadcasts it: `{:ok, n}`, `{:ok, :duplicate}` or `{:error, changeset}`.
  """
  def notify(attrs) do
    %Notification{}
    |> Notification.changeset(normalize(attrs))
    |> Repo.insert()
    |> case do
      {:ok, notification} ->
        Events.broadcast(Events.notifications_topic(), {:notification_created, notification})
        {:ok, notification}

      {:error, changeset} ->
        if duplicate?(changeset), do: {:ok, :duplicate}, else: {:error, changeset}
    end
  end

  @doc "The bell's contents: the newest notifications and the unread count, in one call."
  def feed(user_id \\ nil) do
    %{notifications: recent(@feed_limit, user_id), unread_count: unread_count(user_id)}
  end

  @doc "The newest notifications `user_id` may see, newest first."
  def recent(limit \\ @feed_limit, user_id \\ nil) do
    Repo.all(
      from n in visible_to(Notification, user_id),
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: ^limit
    )
  end

  @doc "How many notifications `user_id` may see have not been read."
  def unread_count(user_id \\ nil) do
    Repo.aggregate(
      from(n in visible_to(Notification, user_id), where: is_nil(n.read_at)),
      :count,
      :id
    )
  end

  @doc "Whether `user_id` may see `notification`."
  def visible?(%Notification{recipient_id: nil}, _user_id), do: true
  def visible?(%Notification{recipient_id: id}, user_id), do: id == user_id

  # The business's notifications, plus the ones addressed to this person.
  defp visible_to(query, nil), do: from(n in query, where: is_nil(n.recipient_id))

  defp visible_to(query, user_id) do
    from n in query, where: is_nil(n.recipient_id) or n.recipient_id == ^user_id
  end

  @doc "Fetches a notification by id, or `nil` for one that is not there."
  def get_notification(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> get_notification(id)
      _not_an_id -> nil
    end
  end

  def get_notification(id) when is_integer(id), do: Repo.get(Notification, id)
  def get_notification(_other), do: nil

  @doc "As `get_notification/1`, but `nil` for one addressed to somebody else."
  def get_notification(id, user_id) do
    case get_notification(id) do
      %Notification{} = notification ->
        if visible?(notification, user_id), do: notification

      nil ->
        nil
    end
  end

  @doc "Marks one notification read. An already-read one keeps its first read time."
  def mark_read(id, user_id \\ nil) do
    case get_notification(id, user_id) do
      nil ->
        {:error, :not_found}

      %Notification{read_at: %DateTime{}} = notification ->
        {:ok, notification}

      notification ->
        notification
        |> Notification.changeset(%{read_at: now()})
        |> Repo.update()
        |> announce_read(notification.id)
    end
  end

  @doc "Marks every unread notification `user_id` can see as read. Returns the count."
  def mark_all_read(user_id \\ nil) do
    {count, _rows} =
      Repo.update_all(
        from(n in visible_to(Notification, user_id), where: is_nil(n.read_at)),
        set: [read_at: now(), updated_at: now()]
      )

    if count > 0 do
      Events.broadcast(Events.notifications_topic(), {:notifications_read, :all})
    end

    count
  end

  @doc "Deletes read notifications older than `days`. Unread ones are kept."
  def prune(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(now(), -days * 24 * 60 * 60, :second)

    {count, _rows} =
      Repo.delete_all(
        from n in Notification,
          where: not is_nil(n.read_at) and n.inserted_at < ^cutoff
      )

    count
  end

  @doc "How many notifications the bell holds."
  def feed_limit, do: @feed_limit

  defdelegate kinds(), to: Notification
  defdelegate severities(), to: Notification

  # Producers pass atom or string keys.
  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp duplicate?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:dedupe_key, {_message, meta}} -> Keyword.get(meta, :constraint) == :unique
      _other_error -> false
    end)
  end

  defp announce_read({:ok, _notification} = result, id) do
    Events.broadcast(Events.notifications_topic(), {:notifications_read, id})
    result
  end

  defp announce_read({:error, _changeset} = result, _id), do: result

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
