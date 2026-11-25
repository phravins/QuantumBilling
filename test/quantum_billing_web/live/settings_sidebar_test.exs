defmodule QuantumBillingWeb.SettingsSidebarTest do
  @moduledoc "The settings menu that replaces the main sidebar on settings pages."
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Accounts

  describe "an owner" do
    setup :register_and_log_in_owner

    test "sees Back, the owner pages and Community", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/company")

      assert has_element?(view, ~s(#settings-back[href="/dashboard"]))
      assert has_element?(view, ~s(#settings-link-company[aria-current="page"]))

      for key <- ~w(profile account team api-keys webhooks data-model audit-logs community) do
        assert has_element?(view, "#settings-link-#{key}"), "expected #{key} in the menu"
      end

      refute has_element?(view, "#settings-link-admin")
    end

    test "Back leaves the settings menu for the main one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/team")

      {:ok, view, _html} =
        view |> element("#settings-back") |> render_click() |> follow_redirect(conn)

      assert has_element?(view, "#nav-invoices")
      refute has_element?(view, "#settings-back")
    end

    test "a super admin also sees the Admin Panel and Layout", %{conn: conn, user: user} do
      {:ok, _user} = Accounts.set_admin(user, true)
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, ~s(#settings-link-admin[href="/admin"]))
      assert has_element?(view, ~s(#settings-link-layout[href="/admin/layout"]))
    end
  end

  describe "staff" do
    setup :register_and_log_in_user

    test "do not see the owner-only pages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#settings-back")
      assert has_element?(view, "#settings-link-profile")
      assert has_element?(view, "#settings-link-community")

      for key <- ~w(team api-keys webhooks data-model audit-logs admin) do
        refute has_element?(view, "#settings-link-#{key}"), "expected no #{key} for staff"
      end
    end
  end
end
