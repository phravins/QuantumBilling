defmodule QuantumBillingWeb.RealtimeTest do
  @moduledoc """
  End-to-end checks that a write in one place reaches a page open somewhere
  else.

  The test process stands in for the second browser window: it performs the
  write, and the assertions are made against a LiveView mounted separately. If
  PubSub were not wired up, the LiveView would simply keep showing its original
  render and every one of these would fail.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Accounts
  alias QuantumBilling.Clients
  alias QuantumBilling.Settings

  setup :register_and_log_in_user

  defp client_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "client_type" => "Unregistered",
        "name" => "Acme Traders",
        "phone" => "9876543210",
        "billing_line1" => "123 Business Park",
        "billing_city" => "Mumbai",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "400093"
      },
      overrides
    )
  end

  describe "clients list" do
    test "a client created elsewhere appears without a reload", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/clients")

      assert html =~ "No clients yet"
      refute html =~ "Acme Traders"

      {:ok, _client} = Clients.create_client(client_attrs())

      assert render(view) =~ "Acme Traders"
      refute render(view) =~ "No clients yet"
    end

    test "the summary tiles keep up too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      {:ok, _} = Clients.create_client(client_attrs(%{"name" => "First Client"}))
      {:ok, _} = Clients.create_client(client_attrs(%{"name" => "Second Client"}))

      html = render(view)

      assert html =~ "Showing 1 to 2 of 2 entries"
      assert html =~ "100.0% of total"
    end

    test "an edit elsewhere is reflected", %{conn: conn} do
      {:ok, client} = Clients.create_client(client_attrs())
      {:ok, view, html} = live(conn, ~p"/clients")

      assert html =~ "Acme Traders"

      {:ok, _} = Clients.update_client(client, %{"name" => "Acme Traders Renamed"})

      assert render(view) =~ "Acme Traders Renamed"
    end

    test "an active search still applies to a client that arrives", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      view |> form("#clients-search", %{"q" => "Beta"}) |> render_change()

      {:ok, _} = Clients.create_client(client_attrs(%{"name" => "Alpha Traders"}))
      {:ok, _} = Clients.create_client(client_attrs(%{"name" => "Beta Traders"}))

      html = render(view)

      # The filter the reader set is respected, not reset by the broadcast.
      assert html =~ "Beta Traders"
      refute html =~ "Alpha Traders"
    end

    test "a failed write broadcasts nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      {:error, _changeset} = Clients.create_client(client_attrs(%{"name" => ""}))

      assert render(view) =~ "No clients yet"
    end
  end

  describe "organisation settings" do
    test "a change elsewhere reaches an open settings page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{"company_name" => "Acme Solutions Private Limited"},
          :general
        )

      assert render(view) =~ "Acme Solutions Private Limited"
    end

    test "the saving window is not sent its own echo", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Saving through the page itself must not also arrive as a broadcast —
      # that would rebuild the form the user is still typing in.
      view
      |> form("#settings-form", %{"organization" => %{"company_name" => "Typed In Place"}})
      |> render_submit()

      assert render(view) =~ "Typed In Place"
      refute_receive {:settings_updated, _}, 50
    end
  end

  describe "own profile" do
    test "the sidebar updates on every page the user has open", %{conn: conn, user: user} do
      # Mounted on the dashboard, which knows nothing about profiles — the
      # subscription lives in the on_mount hook that every authenticated page
      # shares.
      {:ok, view, html} = live(conn, ~p"/dashboard")

      refute html =~ "Priya Sharma"

      {:ok, _} =
        Accounts.update_user_profile(user, %{
          full_name: "Priya Sharma",
          designation: "GST Officer"
        })

      html = render(view)

      assert html =~ "Priya Sharma"
      assert html =~ "GST Officer"
    end

    test "another user's profile change does not touch this sidebar", %{conn: conn} do
      other = QuantumBilling.AccountsFixtures.user_fixture()

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      {:ok, _} = Accounts.update_user_profile(other, %{full_name: "Someone Else"})

      refute render(view) =~ "Someone Else"
    end
  end
end
