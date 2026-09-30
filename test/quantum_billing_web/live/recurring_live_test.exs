defmodule QuantumBillingWeb.RecurringLiveTest do
  @moduledoc """
  The recurring billing page, which had no test of its own.

  Both of its lists were unbounded: every profile, with its client preloaded,
  was reloaded on mount and again after every pause, delete and manual run, and
  the new-profile modal rendered every client in the directory as an
  `<option>`. This covers the paging and the bounded picker that replaced them,
  and the actions that used to trigger the full reload.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Clients
  alias QuantumBilling.Recurring

  setup :register_and_log_in_user

  defp client(name \\ "Acme Traders") do
    {:ok, client} =
      Clients.create_client(%{
        "client_type" => "Unregistered",
        "name" => name,
        "phone" => "9876543210",
        "billing_line1" => "1 Main Street",
        "billing_city" => "Mumbai",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "400001"
      })

    client
  end

  defp profile(client, attrs \\ %{}) do
    {:ok, profile} =
      Recurring.create_profile(
        Map.merge(
          %{
            "client_id" => client.id,
            "title" => "Monthly retainer",
            "frequency" => "Monthly",
            "next_run_date" => Date.to_iso8601(Date.utc_today())
          },
          attrs
        )
      )

    profile
  end

  test "renders an empty state before anything is scheduled", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/recurring")

    assert html =~ "No recurring billing profiles yet"
  end

  test "lists a profile with its client", %{conn: conn} do
    client = client("Northwind Traders")
    profile(client, %{"title" => "Northwind retainer"})

    {:ok, _view, html} = live(conn, ~p"/recurring")

    assert html =~ "Northwind retainer"
    assert html =~ "Northwind Traders"
    assert html =~ "Monthly"
  end

  test "pages rather than listing every profile", %{conn: conn} do
    client = client()

    for index <- 1..12 do
      profile(client, %{
        "title" => "Retainer #{String.pad_leading(to_string(index), 2, "0")}",
        "next_run_date" => Date.to_iso8601(Date.add(Date.utc_today(), index))
      })
    end

    {:ok, view, html} = live(conn, ~p"/recurring")

    # Soonest first, ten to a page.
    assert html =~ "Retainer 01"
    refute html =~ "Retainer 11"

    html = render_click(view, "paginate", %{"page" => "2"})
    assert html =~ "Retainer 11"
    assert html =~ "Retainer 12"
    refute html =~ "Retainer 01"
  end

  test "the client picker is bounded and searchable", %{conn: conn} do
    client("Northwind Traders")
    client("Contoso Logistics")

    {:ok, view, html} = live(conn, ~p"/recurring")

    html = render_click(view, "toggle_modal", %{})
    assert html =~ "Northwind Traders"
    assert html =~ "Contoso Logistics"

    html = render_keyup(view, "search_clients", %{"value" => "Northwind"})
    assert html =~ "Northwind Traders"
    refute html =~ "Contoso Logistics"

    html = render_keyup(view, "search_clients", %{"value" => "nobody at all"})
    assert html =~ "No clients match that search"
  end

  test "pausing a profile reloads only the page being looked at", %{conn: conn} do
    client = client()
    profile = profile(client, %{"title" => "Pausable retainer"})

    {:ok, view, _html} = live(conn, ~p"/recurring")

    html = render_click(view, "toggle_status", %{"id" => to_string(profile.id)})

    assert html =~ "Paused"
    assert Recurring.get_profile!(profile.id).status == "Paused"

    html = render_click(view, "toggle_status", %{"id" => to_string(profile.id)})
    assert html =~ "Active"
  end

  test "deleting a profile moves it to the Bin", %{conn: conn} do
    client = client()
    profile = profile(client, %{"title" => "Doomed retainer"})

    {:ok, view, _html} = live(conn, ~p"/recurring")
    assert has_element?(view, "#profile-#{profile.id}", "Doomed retainer")

    # The confirmation says where it is going, not that it is gone for good.
    assert has_element?(view, ~s|#recurring-delete-#{profile.id}[data-confirm*="Bin"]|)

    view |> element("#recurring-delete-#{profile.id}") |> render_click()

    refute has_element?(view, "#profile-#{profile.id}")
    assert has_element?(view, "#flash-info", "moved to the Bin")

    assert Recurring.get_profile(profile.id) == nil
    assert Recurring.get_deleted_profile(profile.id).title == "Doomed retainer"

    {:ok, bin, _html} = live(conn, ~p"/bin")
    assert has_element?(bin, "#bin-recurring-#{profile.id}", "Doomed retainer")
  end

  test "deleting a profile that is already gone says so", %{conn: conn} do
    client = client()
    profile = profile(client)

    {:ok, view, _html} = live(conn, ~p"/recurring")

    {:ok, _binned} = Recurring.delete_profile(profile)
    render_click(view, "delete", %{"id" => to_string(profile.id)})

    assert has_element?(view, "#flash-error", "no longer exists")
  end

  test "creating a profile through the modal", %{conn: conn} do
    client = client("Northwind Traders")

    {:ok, view, _html} = live(conn, ~p"/recurring")
    render_click(view, "toggle_modal", %{})

    html =
      view
      |> form("#recurring-profile-form", %{
        "recurring_profile" => %{
          "title" => "New retainer",
          "client_id" => to_string(client.id),
          "frequency" => "Quarterly",
          "next_run_date" => Date.to_iso8601(Date.utc_today())
        }
      })
      |> render_submit()

    assert html =~ "New retainer"
    assert html =~ "Quarterly"
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/recurring")
  end

  describe "Recurring.page/1" do
    test "counts and clamps like the other list pages" do
      client = client()
      for index <- 1..25, do: profile(client, %{"title" => "Retainer #{index}"})

      assert %{total: 25, total_pages: 3, page: 1, rows: rows} = Recurring.page(per_page: 10)
      assert length(rows) == 10

      # Past the end clamps rather than returning nothing.
      assert %{page: 3, rows: last} = Recurring.page(page: 99, per_page: 10)
      assert length(last) == 5

      assert Recurring.page(per_page: 100_000).per_page == 200
      assert Recurring.page(per_page: 0).per_page == 1
    end

    test "does not show a profile twice when run dates collide" do
      client = client()
      today = Date.to_iso8601(Date.utc_today())

      for index <- 1..25 do
        profile(client, %{"title" => "Retainer #{index}", "next_run_date" => today})
      end

      titles =
        for page <- 1..3, row <- Recurring.page(page: page, per_page: 10).rows, do: row.title

      assert length(titles) == 25
      assert length(Enum.uniq(titles)) == 25
    end

    test "filters by status" do
      client = client()
      active = profile(client, %{"title" => "Active one"})
      paused = profile(client, %{"title" => "Paused one"})
      {:ok, _} = Recurring.update_profile(paused, %{"status" => "Paused"})

      assert %{total: 1, rows: [row]} = Recurring.page(status: "Active")
      assert row.id == active.id

      assert %{total: 2} = Recurring.page(status: "All Status")
    end
  end
end
