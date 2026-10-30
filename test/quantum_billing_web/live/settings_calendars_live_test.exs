defmodule QuantumBillingWeb.SettingsCalendarsLiveTest do
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Businesses
  alias QuantumBilling.Calendars

  @stub QuantumBilling.Calendars
  @password "app-password-not-real"

  setup do
    Req.Test.set_req_test_to_shared()
    :ok
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    test "shows all three calendars", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      assert has_element?(view, "#calendar-google")
      assert has_element?(view, "#calendar-caldav")
      assert has_element?(view, "#calendar-feed")
    end

    test "Google says it is not configured without an OAuth client", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      assert has_element?(view, "#google-not-configured")
      refute has_element?(view, "#google-connect")
    end

    test "a CalDAV calendar connects, and its password is not shown again", %{conn: conn} do
      Req.Test.stub(@stub, fn conn ->
        Plug.Conn.send_resp(conn, if(conn.method == "PROPFIND", do: 207, else: 201), "")
      end)

      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      html =
        view
        |> form("#caldav-form",
          caldav: %{
            url: "https://calendar.example.com/dav/",
            username: "me",
            password: @password
          }
        )
        |> render_submit()

      refute html =~ @password
      assert has_element?(view, "#calendar-disconnect-caldav")
      refute has_element?(view, "#caldav-form")
    end

    test "an internal CalDAV address stays on the form with an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      html =
        view
        |> form("#caldav-form",
          caldav: %{url: "https://127.0.0.1/dav/", username: "me", password: @password}
        )
        |> render_submit()

      assert html =~ "own network"
      refute html =~ @password
      assert has_element?(view, "#caldav-form")
    end

    test "a feed URL is shown once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      view |> element("#feed-create") |> render_click()
      assert has_element?(view, "#feed-url")

      {:ok, view, _html} = live(conn, ~p"/settings/integrations")
      refute has_element?(view, "#feed-url")
      assert has_element?(view, "#feed-active")
    end

    test "turning the feed off removes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      view |> element("#feed-create") |> render_click()
      view |> element("#calendar-disconnect-feed") |> render_click()

      assert has_element?(view, "#feed-create")
    end

    test "a forged provider changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      html = render_click(view, "disconnect_calendar", %{"provider" => "users"})

      assert html =~ "already disconnected"
    end
  end

  # The section is refused on navigation, so these are sent from a section staff can open.
  describe "as staff" do
    setup :register_and_log_in_user

    setup %{user: user, scope: scope} do
      _ = user
      %{owner_scope: %{scope | business: Businesses.default!()}}
    end

    test "cannot open the section", %{conn: conn} do
      assert {:error, {_kind, %{to: "/settings/general"}}} =
               live(conn, ~p"/settings/integrations")
    end

    test "cannot send the events from another section", %{conn: conn, owner_scope: scope} do
      {:ok, _token} = Calendars.regenerate_feed(scope)
      {:ok, view, _html} = live(conn, ~p"/settings/general")

      for {event, params} <- [
            {"disconnect_calendar", %{"provider" => "feed"}},
            {"regenerate_feed", %{}},
            {"sync_calendars", %{}},
            {"connect_caldav",
             %{
               "caldav" => %{
                 "url" => "https://x.example.com",
                 "username" => "a",
                 "password" => "b"
               }
             }}
          ] do
        assert render_click(view, event, params) =~ "limited to account owners"
      end

      assert Map.keys(Calendars.connections(scope)) == ["feed"]
    end
  end
end
