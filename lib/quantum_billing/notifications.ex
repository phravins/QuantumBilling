defmodule QuantumBilling.Notifications do
  @moduledoc """
  The in-app notification feed, and the real-time delivery of it.

  ## What this is for

  The bell in the top bar used to be decoration: a button with a red dot
  painted on it, no table behind it and nothing that ever cleared it. This is
  the feed it should have been showing. Every row here records something that
  actually happened in the business — an invoice raised, a payment cleared, an
  e-way bill generated or cancelled, a filing falling due, an email that could
  not be delivered.

  ## Real time

  `notify/1` writes the row and then publishes it on `Events.notifications_topic/0`.
  Every authenticated page subscribes through `QuantumBillingWeb.NotificationsHook`,
  so a notification raised by a webhook, an Oban worker or another user's window
  appears in the bell of every open tab without a refresh and without any page
  knowing it happened.

  Publishing is deliberately the *last* thing `notify/1` does, and its result is
  ignored: a notification must never be the reason a payment fails to
  reconcile.

  ## Scope and read state

  The feed belongs to the organisation rather than to one user, which is how
  every other record in this application works — two signed-in people are
  looking at the same clients, the same invoices and the same books. `read_at`
  follows from that: marking a notification read marks it read for the
  business, not for you. Per-user read state needs a join table and belongs
  with the rest of the per-user work.

  ## Writing one twice

  Producers are not all one-shot. The filing reminder runs every morning
  against the same deadline; a payment webhook is redelivered; a recurring
  sweep re-raises the same invoice. Each passes a `dedupe_key` naming the thing
  rather than the moment — `"compliance:GSTR-1:2027-02-11"` — and a repeat
  returns `{:ok, :duplicate}` instead of adding a second identical line. That
  makes every producer safe to call from a retrying job.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Events
  alias QuantumBilling.Notifications.Notification
  alias QuantumBilling.Repo

  # How many the bell holds. The panel is a glance at what just happened, not
  # an archive — anything older is reached through the page it points at.
  @feed_limit 15

  @doc """
  Subscribes the caller to the notification feed.

  Messages are `{:notification_created, notification}` and
  `{:notifications_read, :all | id}`.
  """
  def subscribe, do: Events.subscribe(Events.notifications_topic())

  @doc """
  Records a notification and announces it to every open page.

  Returns `{:ok, notification}`, `{:ok, :duplicate}` when a row with the same
  `dedupe_key` already exists, or `{:error, changeset}`.

  Callers are expected to ignore the result. Nothing in the application should
  behave differently because a notification could not be written.
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

  @doc """
  The bell's contents: the newest notifications and how many are unread.

  One call rather than two, because every page needs both on mount and both
  again on every change, and they must agree with each other.
  """
  def feed(limit \\ @feed_limit) do
    %{notifications: recent(limit), unread_count: unread_count()}
  end

  @doc "The newest notifications, newest first."
  def recent(limit \\ @feed_limit) do
    Repo.all(
      from n in Notification,
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: ^limit
    )
  end

  @doc "How many notifications have not been read."
  def unread_count do
    Repo.aggregate(from(n in Notification, where: is_nil(n.read_at)), :count, :id)
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

  @doc """
  Marks one notification read.

  Already-read rows are left with the time they were first read rather than
  re-stamped, so opening the same notice twice does not move it.
  """
  def mark_read(id) do
    case get_notification(id) do
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

  @doc """
  Marks every unread notification read.

  Returns the number cleared.
  """
  def mark_all_read do
    {count, _rows} =
      Repo.update_all(
        from(n in Notification, where: is_nil(n.read_at)),
        set: [read_at: now(), updated_at: now()]
      )

    if count > 0 do
      Events.broadcast(Events.notifications_topic(), {:notifications_read, :all})
    end

    count
  end

  @doc """
  Deletes read notifications older than `days`.

  Unread ones are kept whatever their age: an unread notice is still news to
  whoever has not seen it, and silently deleting it would be the feed losing
  the one thing it exists to hold. Called from `AuditPruneWorker` with the
  other ledgers that grow for ever.
  """
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

  # Accepts either key style, because producers here are a mix of contexts
  # writing atoms and workers building maps from job args.
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
