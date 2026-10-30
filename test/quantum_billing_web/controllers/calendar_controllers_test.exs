defmodule QuantumBillingWeb.CalendarControllersTest do
  use QuantumBillingWeb.ConnCase, async: false

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.Calendars

  @stub QuantumBilling.Calendars

  setup do
    Req.Test.set_req_test_to_shared()
    :ok
  end

  defp configure_google do
    previous = Application.get_env(:quantum_billing, :google_calendar)

    Application.put_env(:quantum_billing, :google_calendar,
      client_id: "client-id",
      client_secret: "client-secret-not-real"
    )

    on_exit(fn -> Application.put_env(:quantum_billing, :google_calendar, previous) end)
  end

  describe "the feed" do
    setup do
      scope = %{
        Scope.for_user(QuantumBilling.AccountsFixtures.user_fixture())
        | business: Businesses.default!()
      }

      {:ok, token} = Calendars.regenerate_feed(scope)
      %{scope: scope, token: token, slug: scope.business.slug}
    end

    test "needs no session, and answers as a calendar", %{conn: conn, slug: slug, token: token} do
      conn = get(conn, "/calendar/#{slug}/#{token}.ics")

      assert response(conn, 200) =~ "BEGIN:VCALENDAR"
      assert ["text/calendar; charset=utf-8"] = get_resp_header(conn, "content-type")
      assert ["private, max-age=900"] = get_resp_header(conn, "cache-control")
      assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
    end

    test "a calendar app asking for text/calendar is not refused", %{
      conn: conn,
      slug: slug,
      token: token
    } do
      conn =
        conn |> put_req_header("accept", "text/calendar") |> get("/calendar/#{slug}/#{token}")

      assert response(conn, 200)
    end

    test "every failure is the same 404", %{conn: conn, slug: slug, token: token} do
      responses =
        for path <- ["/calendar/#{slug}/wrong", "/calendar/no-such/#{token}", "/calendar/%00/x"] do
          conn = get(conn, path)
          {conn.status, conn.resp_body}
        end

      assert Enum.uniq(responses) == [{404, "Not found"}]
    end

    test "the token stays out of the request log", %{conn: conn, slug: slug, token: token} do
      conn = get(conn, "/calendar/#{slug}/#{token}")

      assert QuantumBillingWeb.Endpoint.log_level(conn) == false
    end

    test "too many requests are refused", %{conn: conn} do
      ip = {203, 0, 113, :rand.uniform(250)}

      statuses =
        for _attempt <- 1..61 do
          conn |> Map.put(:remote_ip, ip) |> get("/calendar/none/none") |> Map.get(:status)
        end

      assert List.last(statuses) == 429
      assert 404 in statuses
    end
  end

  describe "connecting Google, as an owner" do
    setup :register_and_log_in_owner

    test "says so when the server has no OAuth client", %{conn: conn} do
      conn = get(conn, ~p"/integrations/google/connect")

      assert redirected_to(conn) == "/settings/integrations"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
    end

    test "goes to Google with a state held in the session", %{conn: conn} do
      configure_google()

      conn = get(conn, ~p"/integrations/google/connect")
      location = URI.parse(redirected_to(conn))

      assert location.host == "accounts.google.com"

      assert URI.decode_query(location.query)["state"] ==
               get_session(conn, :google_calendar_oauth)["state"]
    end

    test "a callback with a wrong state connects nothing", %{conn: conn} do
      configure_google()
      started = get(conn, ~p"/integrations/google/connect")

      conn =
        started
        |> recycle_session()
        |> get(~p"/integrations/google/callback", %{"state" => "forged", "code" => "x"})

      assert redirected_to(conn) == "/settings/integrations"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be verified"
      assert get_session(conn, :google_calendar_oauth) == nil
    end

    test "a callback nobody started connects nothing", %{conn: conn} do
      conn = get(conn, ~p"/integrations/google/callback", %{"state" => "any", "code" => "x"})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be verified"
    end

    test "the right state connects, and cannot be used twice", %{conn: conn} do
      configure_google()

      Req.Test.stub(@stub, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "a", "refresh_token" => "r"})

          _events ->
            Req.Test.json(conn, %{"etag" => "e"})
        end
      end)

      started = get(conn, ~p"/integrations/google/connect")
      state = get_session(started, :google_calendar_oauth)["state"]

      done =
        started
        |> recycle_session()
        |> get(~p"/integrations/google/callback", %{"state" => state, "code" => "x"})

      assert Phoenix.Flash.get(done.assigns.flash, :info) =~ "connected"
      assert get_session(done, :google_calendar_oauth) == nil

      again =
        done
        |> recycle_session()
        |> get(~p"/integrations/google/callback", %{"state" => state, "code" => "x"})

      assert Phoenix.Flash.get(again.assigns.flash, :error) =~ "could not be verified"
    end

    test "declining at Google connects nothing", %{conn: conn} do
      configure_google()
      started = get(conn, ~p"/integrations/google/connect")
      state = get_session(started, :google_calendar_oauth)["state"]

      conn =
        started
        |> recycle_session()
        |> get(~p"/integrations/google/callback", %{"state" => state, "error" => "access_denied"})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not connected"
    end

    defp recycle_session(conn) do
      session = conn.private.plug_session

      conn
      |> recycle()
      |> Plug.Test.init_test_session(session)
    end
  end

  describe "connecting Google, as anyone else" do
    test "someone signed out is sent to sign in", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/integrations/google/connect")) == "/users/log-in"
      assert redirected_to(get(conn, ~p"/integrations/google/callback")) == "/users/log-in"
    end

    test "staff are refused", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      for path <- [~p"/integrations/google/connect", ~p"/integrations/google/callback"] do
        conn = get(conn, path)
        refute conn.status == 200
        refute String.contains?(to_string(get_resp_header(conn, "location")), "google.com")
      end
    end
  end
end
