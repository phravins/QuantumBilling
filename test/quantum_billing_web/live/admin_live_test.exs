defmodule QuantumBillingWeb.AdminLiveTest do
  @moduledoc "The super admin's Admin Panel: who may see it, and its three tabs."
  # Not async: the config test sets an environment variable.
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts
  alias QuantumBilling.InstallationSettings

  setup :register_and_log_in_owner

  # GitHub answers nothing, so the latest version shows as unknown.
  setup do
    Req.Test.stub(QuantumBilling.GitHub, &Plug.Conn.send_resp(&1, 404, ""))
    :ok
  end

  defp make_admin(%{user: user}) do
    {:ok, user} = Accounts.set_admin(user, true)
    %{user: user}
  end

  describe "a business owner who is not a super admin" do
    test "gets a 404 for every admin page", %{conn: conn} do
      for path <- [~p"/admin", ~p"/admin/config", ~p"/admin/health", ~p"/admin/layout"] do
        assert_error_sent 404, fn -> get(conn, path) end
      end
    end

    test "has no Admin Panel in the settings menu", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      refute has_element?(view, "#settings-link-admin")
      refute has_element?(view, "#settings-link-layout")
    end
  end

  describe "a super admin" do
    setup :make_admin

    test "sees the General tab: versions, admins, users and businesses", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#settings-back")
      assert has_element?(view, ~s(#settings-link-admin[aria-current="page"]))
      assert has_element?(view, ~s(#admin-tab-general[aria-current="page"]))
      assert has_element?(view, "#admin-tab-config")
      assert has_element?(view, "#admin-tab-health")

      render_async(view, 2_000)
      assert has_element?(view, "#admin-current-version")
      assert has_element?(view, "#admin-latest-version")
      assert has_element?(view, "#admin-admins #admin-#{user.id}")
      assert has_element?(view, "#admin-user-rows #users-#{user.id}")
      assert has_element?(view, "#admin-business-rows")
    end

    test "searches the users", %{conn: conn, user: user} do
      other = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> form("#user-search-form", users: %{q: other.email}) |> render_change()

      assert has_element?(view, "#users-#{other.id}")
      refute has_element?(view, "#users-#{user.id}")
    end

    test "Config lists the settings and never shows a secret", %{conn: conn} do
      secret = "s3cret-#{System.unique_integer([:positive])}"
      previous = System.get_env("SMTP_PASSWORD")
      System.put_env("SMTP_PASSWORD", secret)

      on_exit(fn ->
        if previous,
          do: System.put_env("SMTP_PASSWORD", previous),
          else: System.delete_env("SMTP_PASSWORD")
      end)

      {:ok, view, html} = live(conn, ~p"/admin/config")

      assert has_element?(view, "#config-SMTP_PASSWORD")
      assert has_element?(view, "#config-PHX_HOST")
      refute html =~ secret
      refute render(view) =~ secret

      view |> form("#config-search-form", config: %{q: "smtp"}) |> render_change()
      assert has_element?(view, "#config-SMTP_PASSWORD")
      refute has_element?(view, "#config-PHX_HOST")
    end

    test "Health shows the checks and the upgrade status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/health")

      assert has_element?(view, ~s(#health-database[data-status="ok"]))
      assert has_element?(view, "#admin-upgrade")

      view |> element("#health-refresh") |> render_click()
      assert has_element?(view, "#health-database")
    end

    test "turns maintenance mode on, which shuts out everyone else", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/health")

      assert has_element?(view, ~s(#maintenance-toggle[aria-checked="false"][data-confirm]))
      view |> element("#maintenance-toggle") |> render_click()

      assert InstallationSettings.maintenance?()
      assert has_element?(view, ~s(#maintenance-toggle[aria-checked="true"]))

      # The admin keeps working; a member is sent to the maintenance page.
      assert {:ok, _view, _html} = live(conn, ~p"/invoices")

      staff_conn = log_in_user(build_conn(), user_fixture())
      assert {:error, {:redirect, %{to: "/maintenance"}}} = live(staff_conn, ~p"/invoices")
      assert html_response(get(build_conn(), ~p"/maintenance"), 503) =~ ~s(id="maintenance")

      view |> element("#maintenance-toggle") |> render_click()
      refute InstallationSettings.maintenance?()
    end
  end
end
