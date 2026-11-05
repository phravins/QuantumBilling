defmodule QuantumBilling.Calendars do
  @moduledoc """
  Sends a business's compliance deadlines to its calendars, one way only.

  Google Calendar and CalDAV are pushed to by `CalendarSyncWorker`; the feed is
  a private URL built on request. A failed sync never blocks saving a task: it
  is recorded on the connection as a fixed sentence and retried.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit
  alias QuantumBilling.Businesses
  alias QuantumBilling.Calendars.CaldavClient
  alias QuantumBilling.Calendars.Connection
  alias QuantumBilling.Calendars.EventLink
  alias QuantumBilling.Calendars.GoogleClient
  alias QuantumBilling.Calendars.ICS
  alias QuantumBilling.Compliance
  alias QuantumBilling.Compliance.Task
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Workers.CalendarSyncWorker

  @push_providers ~w(google caldav)
  @feed_token_bytes 32

  # Connections

  @doc "This business's connections, by provider."
  def connections(%Scope{} = scope) do
    in_business(scope, fn -> Connection |> Repo.all() |> Map.new(&{&1.provider, &1}) end)
  end

  def change_caldav(attrs \\ %{}), do: Connection.caldav_changeset(%Connection{}, attrs)

  @doc """
  Saves a CalDAV connection once the server accepts the login; otherwise returns the reason.
  """
  def connect_caldav(%Scope{} = scope, attrs) do
    changeset = change_caldav(attrs)

    with {:ok, valid} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- verify_caldav(changeset, valid) do
      save_connection(scope, "caldav",
        secret: valid.password,
        url: valid.url,
        username: valid.username
      )
    end
  end

  defp verify_caldav(changeset, valid) do
    case CaldavClient.verify(valid.url, valid.username, valid.password) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(:url, caldav_problem(reason))
         |> Map.put(:action, :insert)}
    end
  end

  defp caldav_problem(:unauthorized), do: "the server refused this username or password"
  defp caldav_problem(:blocked), do: "cannot point inside the server's own network"
  defp caldav_problem(_reason), do: "this address did not answer as a CalDAV calendar"

  @doc "Saves a Google connection from the code in the OAuth callback."
  def connect_google(%Scope{} = scope, code, redirect_uri) do
    with {:ok, refresh_token} <- GoogleClient.exchange_code(code, redirect_uri) do
      save_connection(scope, "google", secret: refresh_token)
    end
  end

  @doc """
  Issues a new feed token and returns it once. Only its hash is kept; older URLs stop working.
  """
  def regenerate_feed(%Scope{} = scope) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(@feed_token_bytes), padding: false)

    with {:ok, _connection} <- save_connection(scope, "feed", feed_token_hash: hash(token)) do
      {:ok, token}
    end
  end

  defp save_connection(%Scope{} = scope, provider, changes) do
    in_business(scope, fn ->
      connection = Repo.get_by(Connection, provider: provider) || %Connection{provider: provider}

      result =
        connection
        |> Ecto.Changeset.change(
          Keyword.merge(changes, connected_by_id: scope.user.id, last_error: nil)
        )
        |> Repo.insert_or_update()

      with {:ok, saved} <- result do
        # A new login may be a different calendar; re-sending is safe since event ids are stable.
        Repo.delete_all(from l in EventLink, where: l.connection_id == ^saved.id)
        log(scope, "calendar_connected", saved)
        _ = enqueue_sync()
      end

      result
    end)
  end

  @doc """
  Removes a connection and revokes the Google grant. Events already sent stay in the calendar.
  """
  def disconnect(%Scope{} = scope, provider) when provider in ["google", "caldav", "feed"] do
    in_business(scope, fn ->
      case Repo.get_by(Connection, provider: provider) do
        nil ->
          {:error, :not_found}

        connection ->
          if provider == "google" and connection.secret,
            do: GoogleClient.revoke(connection.secret)

          with {:ok, deleted} <- Repo.delete(connection) do
            log(scope, "calendar_disconnected", deleted)
            {:ok, deleted}
          end
      end
    end)
  end

  def disconnect(%Scope{}, _provider), do: {:error, :not_found}

  defp log(scope, action, connection) do
    Audit.log_event(action, "CalendarConnection", connection.id,
      user_id: scope.user.id,
      details: %{provider: connection.provider}
    )
  end

  defp in_business(%Scope{business: business}, fun), do: Repo.with_business(business, fun)

  # Feed

  @doc "The feed for `slug` and `token`, or `:error`. Every failure looks the same."
  def feed(slug, token) when is_binary(slug) and is_binary(token) do
    with true <- Regex.match?(~r/\A[a-z0-9-]{1,100}\z/, slug),
         %{} = business <- Businesses.get_by_slug(slug) do
      Repo.with_business(business, fn ->
        with %Connection{feed_token_hash: stored} when is_binary(stored) <-
               Repo.get_by(Connection, provider: "feed"),
             true <- Plug.Crypto.secure_compare(stored, hash(token)) do
          {:ok, ICS.calendar(business.name, Enum.map(items(), &{uid(business, &1), &1}))}
        else
          _other -> :error
        end
      end)
    else
      _other -> :error
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  # What goes on a calendar

  @doc """
  Open, non-private tasks plus GST returns due from today, including last year's March returns.
  """
  def items(%Date{} = today \\ Date.utc_today()) do
    task_items() ++ obligation_items(today)
  end

  defp task_items do
    # A private task stays off the business's shared calendar.
    Task
    |> where([t], t.status == "open" and not t.private)
    |> order_by([t], asc: t.due_date, asc: t.id)
    |> Repo.all()
    |> Enum.map(fn task ->
      %{
        key: "task:#{task.id}",
        title: task.title,
        description: task.notes,
        date: task.due_date,
        alarm_days: task.remind_days_before
      }
    end)
  end

  defp obligation_items(today) do
    organization = Settings.get_organization()
    lead = organization.reminder_lead_days || 7

    [today, Compliance.shift_months(today, -12)]
    |> Enum.flat_map(&Compliance.tracked_obligations(&1, organization))
    |> Enum.filter(&(Date.compare(&1.due_date, today) != :lt))
    |> Enum.map(fn obligation ->
      %{
        key: "gst:#{obligation.type}:#{Date.to_iso8601(obligation.due_date)}",
        title: "#{obligation.type} due (#{obligation.period_label})",
        description: "GST return, tracked in QuantumBilling.",
        date: obligation.due_date,
        alarm_days: lead
      }
    end)
    |> Enum.uniq_by(& &1.key)
  end

  # The same event on every sync, so a retry never adds a second one.
  defp uid(business, item) do
    key = String.replace(item.key, ~r/[^A-Za-z0-9]+/, "-")
    "qb-#{business.id}-#{key}@quantumbilling"
  end

  # Sync

  @doc "Queues a sync if this business pushes to any calendar. Never raises."
  def enqueue_sync do
    if Repo.exists?(from c in Connection, where: c.provider in @push_providers) do
      %{} |> CalendarSyncWorker.new() |> Oban.insert()
    else
      :ok
    end
  rescue
    _error -> :error
  end

  @doc """
  Syncs every pushed calendar: `:ok` or `{:error, sentence}` for the first problem, after trying all.
  """
  def sync_all(%Date{} = today \\ Date.utc_today()) do
    from(c in Connection, where: c.provider in @push_providers)
    |> Repo.all()
    |> Enum.map(&sync(&1, today))
    |> Enum.find(:ok, &match?({:error, _message}, &1))
  end

  @doc "Syncs one connection and records how it went."
  def sync(%Connection{} = connection, %Date{} = today \\ Date.utc_today()) do
    result =
      with {:ok, client} <- open(connection) do
        items = items(today)
        links = links(connection)

        with :ok <- push(connection, client, items, links) do
          remove_stale(client, items, links, today)
        end
      end

    record(connection, result)
  end

  defp open(%Connection{provider: "google"} = connection) do
    with {:ok, token} <- GoogleClient.access_token(connection.secret) do
      {:ok, {:google, token, connection.calendar_id}}
    end
  end

  defp open(%Connection{provider: "caldav"} = connection) do
    {:ok, {:caldav, connection.url, connection.username, connection.secret}}
  end

  defp links(connection) do
    from(l in EventLink, where: l.connection_id == ^connection.id)
    |> Repo.all()
    |> Map.new(&{&1.item_key, &1})
  end

  # Stops at the first failure; what was sent stays recorded, so the retry resumes.
  defp push(connection, client, items, links) do
    business = Repo.business()

    Enum.reduce_while(items, :ok, fn item, :ok ->
      link = Map.get(links, item.key)
      print = fingerprint(item)

      if link && link.fingerprint == print do
        {:cont, :ok}
      else
        case send_event(client, uid(business, item), item, link) do
          {:ok, external_id, etag} ->
            save_link(connection, link, item, external_id, etag, print)
            {:cont, :ok}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end
    end)
  end

  defp send_event({:google, token, calendar_id}, uid, item, link) do
    event_id = Base.hex_encode32(uid, case: :lower, padding: false)
    GoogleClient.put_event(token, calendar_id, event_id, item, not is_nil(link))
  end

  defp send_event({:caldav, url, username, password}, uid, item, _link) do
    CaldavClient.put_event(url, username, password, uid, ICS.single_event(uid, item))
  end

  defp save_link(connection, link, item, external_id, etag, print) do
    link = link || %EventLink{connection_id: connection.id, item_key: item.key}

    link
    |> Ecto.Changeset.change(
      external_id: external_id,
      etag: etag,
      fingerprint: print,
      due_date: item.date
    )
    |> Repo.insert_or_update!()
  end

  # Tasks leave once done or deleted; past GST deadlines stay as a record.
  defp remove_stale(client, items, links, today) do
    current = MapSet.new(items, & &1.key)

    links
    |> Map.values()
    |> Enum.reject(&MapSet.member?(current, &1.item_key))
    |> Enum.filter(&removable?(&1, today))
    |> Enum.reduce_while(:ok, fn link, :ok ->
      case delete_event(client, link) do
        :ok ->
          Repo.delete!(link)
          {:cont, :ok}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp removable?(%EventLink{item_key: "task:" <> _id}, _today), do: true
  defp removable?(%EventLink{due_date: due_date}, today), do: Date.compare(due_date, today) != :lt

  defp delete_event({:google, token, calendar_id}, link) do
    GoogleClient.delete_event(token, calendar_id, link.external_id)
  end

  defp delete_event({:caldav, _url, username, password}, link) do
    CaldavClient.delete_event(link.external_id, username, password)
  end

  defp fingerprint(item) do
    {item.title, item.description, item.date, item.alarm_days}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp record(connection, :ok) do
    connection
    |> Ecto.Changeset.change(
      last_synced_at: DateTime.utc_now(:second),
      last_error: nil
    )
    |> Repo.update!()

    :ok
  end

  defp record(connection, {:error, reason}) do
    message = problem(reason)

    connection
    |> Ecto.Changeset.change(last_error: message)
    |> Repo.update!()

    {:error, message}
  end

  # Fixed sentences: a server's own error text might carry a credential.
  defp problem(:reauthorize), do: "Google no longer accepts this connection. Connect it again."
  defp problem(:unauthorized), do: "The calendar refused the saved login. Connect it again."
  defp problem(:blocked), do: "The calendar address points inside the server's own network."
  defp problem(_reason), do: "The calendar did not respond as expected. It will be tried again."
end
