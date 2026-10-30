defmodule QuantumBilling.CalendarsTest do
  use QuantumBilling.DataCase, async: false

  import ExUnit.CaptureLog
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.Calendars
  alias QuantumBilling.Calendars.CaldavClient
  alias QuantumBilling.Calendars.Connection
  alias QuantumBilling.Calendars.EventLink
  alias QuantumBilling.Calendars.GoogleClient
  alias QuantumBilling.Compliance
  alias QuantumBilling.Settings

  @stub QuantumBilling.Calendars
  @password "app-password-not-real"
  @refresh_token "refresh-token-not-real"
  @url "https://calendar.example.com/dav/work/"

  setup do
    Req.Test.set_req_test_to_shared()
    scope = %{Scope.for_user(user_fixture()) | business: Businesses.default!()}
    %{scope: scope}
  end

  defp task(scope, attrs \\ %{}) do
    {:ok, task} =
      Compliance.create_task(
        scope,
        "task",
        Map.merge(
          %{"title" => "Renew licence", "due_date" => Date.add(Date.utc_today(), 10)},
          attrs
        )
      )

    task
  end

  # Records each request's method and path, then answers.
  defp stub_caldav(status \\ 201) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:caldav, conn.method, conn.request_path, body, conn.req_headers})

      conn
      |> Plug.Conn.put_resp_header("etag", "\"abc\"")
      |> Plug.Conn.send_resp(if(conn.method == "PROPFIND", do: 207, else: status), "")
    end)
  end

  defp caldav_attrs do
    %{"url" => @url, "username" => "me", "password" => @password}
  end

  defp connect_caldav(scope) do
    stub_caldav()
    {:ok, connection} = Calendars.connect_caldav(scope, caldav_attrs())
    flush()
    connection
  end

  defp flush do
    receive do
      {:caldav, _, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp configure_google do
    previous = Application.get_env(:quantum_billing, :google_calendar)

    Application.put_env(:quantum_billing, :google_calendar,
      client_id: "client-id",
      client_secret: "client-secret-not-real"
    )

    on_exit(fn -> Application.put_env(:quantum_billing, :google_calendar, previous) end)
  end

  describe "CalDAV" do
    test "the login is checked before anything is saved", %{scope: scope} do
      stub_caldav()

      assert {:ok, connection} = Calendars.connect_caldav(scope, caldav_attrs())
      assert_received {:caldav, "PROPFIND", "/dav/work/", _body, headers}
      assert {"depth", "0"} in headers

      assert connection.provider == "caldav"
      assert connection.connected_by_id == scope.user.id
    end

    test "a refused login stores nothing", %{scope: scope} do
      Req.Test.stub(@stub, &Plug.Conn.send_resp(&1, 401, ""))

      assert {:error, changeset} = Calendars.connect_caldav(scope, caldav_attrs())
      assert "the server refused this username or password" in errors_on(changeset).url
      assert Calendars.connections(scope) == %{}
    end

    test "the password is encrypted at rest and hidden from inspect", %{scope: scope} do
      connection = connect_caldav(scope)

      refute inspect(connection) =~ @password
      refute inspect(Repo.get!(Connection, connection.id)) =~ @password

      %{rows: [[stored]]} =
        Repo.query!(
          "SELECT secret FROM #{scope.business.schema}.calendar_connections WHERE id = $1",
          [connection.id]
        )

      refute stored =~ @password
      assert Repo.get!(Connection, connection.id).secret == @password
    end

    for url <- [
          "https://127.0.0.1/dav/",
          "https://localhost/dav/",
          "https://169.254.169.254/latest/",
          "https://10.0.0.5/dav/"
        ] do
      test "refuses the internal address #{url}", %{scope: scope} do
        attrs = Map.put(caldav_attrs(), "url", unquote(url))

        assert {:error, changeset} = Calendars.connect_caldav(scope, attrs)
        assert errors_on(changeset).url != []
      end
    end

    test "refuses plain http, and a login inside the URL", %{scope: scope} do
      for url <- ["http://calendar.example.com/dav/", "https://me:secret@calendar.example.com/"] do
        attrs = Map.put(caldav_attrs(), "url", url)
        assert {:error, changeset} = Calendars.connect_caldav(scope, attrs)
        assert errors_on(changeset).url != []
      end
    end

    test "the guard runs again before each request" do
      assert CaldavClient.put_event("https://127.0.0.1/dav/", "me", @password, "uid", "ics") ==
               {:error, :blocked}

      assert CaldavClient.delete_event("https://127.0.0.1/dav/x.ics", "me", @password) ==
               {:error, :blocked}
    end

    test "a task goes out as one PUT, and an unchanged one is not sent again", %{scope: scope} do
      connection = connect_caldav(scope)
      task = task(scope)
      flush()

      assert :ok = Repo.with_business(scope.business, fn -> Calendars.sync_all() end)
      refute_received {:caldav, "PUT", _, _, _}

      link =
        Repo.with_business(scope.business, fn ->
          Repo.get_by!(EventLink, connection_id: connection.id, item_key: "task:#{task.id}")
        end)

      assert link.etag == "\"abc\""
      assert link.external_id =~ @url
    end

    test "changing a task sends it again under the same address", %{scope: scope} do
      connect_caldav(scope)
      task = task(scope)
      assert_task_put(task)

      {:ok, _task} = Compliance.update_task(scope, task, %{"title" => "Renew the licence"})

      assert_received {:caldav, "PUT", path, body, _headers}
      assert body =~ "SUMMARY:Renew the licence"
      assert path =~ "task-#{task.id}"
    end

    test "a finished task is removed from the calendar", %{scope: scope} do
      connect_caldav(scope)
      task = task(scope)
      assert_task_put(task)

      {:ok, _task} = Compliance.complete_task(scope, task)

      assert_received {:caldav, "DELETE", path, _body, _headers}
      assert path =~ "task-#{task.id}"
    end

    test "a failed sync is recorded in fixed words and does not stop the save", %{scope: scope} do
      connection = connect_caldav(scope)

      Req.Test.stub(@stub, fn conn ->
        Plug.Conn.send_resp(conn, 500, "server secret: #{@password}")
      end)

      assert %{title: "Renew licence"} = task(scope)

      saved = Repo.with_business(scope.business, fn -> Repo.get!(Connection, connection.id) end)

      assert saved.last_error ==
               "The calendar did not respond as expected. It will be tried again."

      refute saved.last_error =~ @password
    end

    test "reconnecting forgets the old links, so a new calendar gets everything", %{scope: scope} do
      connect_caldav(scope)
      task(scope)
      flush()

      stub_caldav()
      {:ok, _connection} = Calendars.connect_caldav(scope, caldav_attrs())

      assert_received {:caldav, "PUT", _path, _body, _headers}
    end

    test "credentials do not reach the log", %{scope: scope} do
      log =
        capture_log(fn ->
          connect_caldav(scope)
          task(scope)
        end)

      refute log =~ @password
    end

    defp assert_task_put(task) do
      assert_received {:caldav, "PUT", path, body, _headers}
      assert path =~ "task-#{task.id}"
      assert body =~ "BEGIN:VEVENT"
      flush()
    end
  end

  describe "items" do
    test "only open tasks are listed", %{scope: scope} do
      open = task(scope)
      done = task(scope, %{"title" => "Already done"})
      {:ok, _done} = Compliance.complete_task(scope, done)

      keys =
        Repo.with_business(scope.business, fn -> Calendars.items() end) |> Enum.map(& &1.key)

      assert "task:#{open.id}" in keys
      refute "task:#{done.id}" in keys
    end

    test "GST returns appear from today on, once each, with the chosen lead", %{scope: scope} do
      today = Date.utc_today()

      items =
        Repo.with_business(scope.business, fn ->
          {:ok, _organization} =
            Settings.update_section(
              Settings.get_organization(),
              %{"gstin" => "27AABCA1234A1Z5", "company_name" => "Northwind"},
              :general
            )

          Calendars.items(today)
        end)

      assert items != []
      assert Enum.all?(items, &(Date.compare(&1.date, today) != :lt))
      assert items == Enum.uniq_by(items, & &1.key)
      assert Enum.all?(items, &is_integer(&1.alarm_days))
    end
  end

  describe "feed" do
    test "the right token gets the calendar", %{scope: scope} do
      task(scope, %{"title" => "Feed task"})
      {:ok, token} = Calendars.regenerate_feed(scope)

      assert {:ok, ics} = Calendars.feed(scope.business.slug, token)
      assert ics =~ "SUMMARY:Feed task"
    end

    test "only a hash of the token is stored", %{scope: scope} do
      {:ok, token} = Calendars.regenerate_feed(scope)
      connection = Calendars.connections(scope)["feed"]

      refute connection.feed_token_hash == token
      refute inspect(connection) =~ token
      refute inspect(connection) =~ Base.encode16(connection.feed_token_hash)
    end

    test "a wrong token, an old token and an unknown business are all refused", %{scope: scope} do
      {:ok, old} = Calendars.regenerate_feed(scope)
      {:ok, _new} = Calendars.regenerate_feed(scope)

      assert Calendars.feed(scope.business.slug, "wrong") == :error
      assert Calendars.feed(scope.business.slug, old) == :error
      assert Calendars.feed("no-such-business", old) == :error
      assert Calendars.feed("bad\0slug", old) == :error
    end

    test "a feed turned off stops working", %{scope: scope} do
      {:ok, token} = Calendars.regenerate_feed(scope)
      {:ok, _connection} = Calendars.disconnect(scope, "feed")

      assert Calendars.feed(scope.business.slug, token) == :error
    end

    test "a token for one business does not open another", %{scope: scope} do
      {:ok, token} = Calendars.regenerate_feed(scope)

      {:ok, other} = Businesses.create(scope.user, %{name: "Second Traders"})

      assert Calendars.feed(other.slug, token) == :error
    end
  end

  describe "Google" do
    test "says whether it is configured" do
      configure_google()
      assert GoogleClient.configured?()

      Application.put_env(:quantum_billing, :google_calendar, client_id: "", client_secret: "")
      refute GoogleClient.configured?()
    end

    test "asks for calendar events only, offline, with the state" do
      configure_google()

      url = URI.parse(GoogleClient.authorize_url("the-state", "https://app.test/callback"))
      query = URI.decode_query(url.query)

      assert url.host == "accounts.google.com"
      assert query["scope"] == "https://www.googleapis.com/auth/calendar.events"
      assert query["access_type"] == "offline"
      assert query["state"] == "the-state"
    end

    defp stub_google(test) do
      Req.Test.stub(@stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:google, conn.method, conn.host, conn.request_path, body})

        case {conn.host, conn.request_path} do
          {"oauth2.googleapis.com", "/token"} ->
            Req.Test.json(conn, %{
              "access_token" => "access-token-not-real",
              "refresh_token" => @refresh_token
            })

          {"oauth2.googleapis.com", "/revoke"} ->
            Plug.Conn.send_resp(conn, 200, "")

          _events ->
            Req.Test.json(conn, %{"etag" => "\"google\"", "id" => "x"})
        end
      end)
    end

    defp connect_google(scope) do
      configure_google()
      stub_google(self())
      {:ok, connection} = Calendars.connect_google(scope, "the-code", "https://app.test/callback")
      connection
    end

    test "the code becomes an encrypted refresh token", %{scope: scope} do
      connection = connect_google(scope)

      assert connection.secret == @refresh_token
      refute inspect(connection) =~ @refresh_token
    end

    test "a task becomes an all-day event with an id of our own", %{scope: scope} do
      connect_google(scope)
      task(scope)

      assert_received {:google, "POST", "www.googleapis.com",
                       "/calendar/v3/calendars/primary/events", body}

      event = Jason.decode!(body)
      assert event["id"] =~ ~r/\A[0-9a-v]+\z/
      assert event["start"]["date"]
      assert event["end"]["date"]
      assert event["transparency"] == "transparent"
    end

    test "an id Google already knows is updated instead", %{scope: scope} do
      connect_google(scope)
      test = self()

      Req.Test.stub(@stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/token"} ->
            Req.Test.json(conn, %{"access_token" => "access-token-not-real"})

          {"POST", _events} ->
            Plug.Conn.send_resp(conn, 409, "")

          {"PUT", path} ->
            send(test, {:updated, path})
            Req.Test.json(conn, %{"etag" => "\"second\""})
        end
      end)

      task(scope)

      assert_received {:updated, "/calendar/v3/calendars/primary/events/" <> _id}
    end

    test "a withdrawn grant asks the owner to connect again", %{scope: scope} do
      connection = connect_google(scope)

      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, message} =
               Repo.with_business(scope.business, fn -> Calendars.sync(connection) end)

      assert message =~ "Connect it again"
    end

    test "disconnecting revokes the grant and removes the row", %{scope: scope} do
      connect_google(scope)

      assert {:ok, _connection} = Calendars.disconnect(scope, "google")
      assert_received {:google, "POST", "oauth2.googleapis.com", "/revoke", _body}
      assert Calendars.connections(scope) == %{}
    end

    test "an unknown provider cannot be disconnected", %{scope: scope} do
      assert Calendars.disconnect(scope, "'; DROP TABLE users") == {:error, :not_found}
    end
  end

  describe "saving a task" do
    test "queues nothing when no calendar is connected", %{scope: scope} do
      # No stub is set, so a request here would raise.
      assert %{title: "Renew licence"} = task(scope)
    end
  end
end
