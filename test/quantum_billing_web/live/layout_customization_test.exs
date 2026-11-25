defmodule QuantumBillingWeb.LayoutCustomizationTest do
  @moduledoc "The super admin arranges the main menu for everyone."
  # Not async: the saved layout is cached for the whole node.
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Accounts
  alias QuantumBilling.InstallationSettings

  setup :register_and_log_in_owner

  setup %{user: user} do
    {:ok, user} = Accounts.set_admin(user, true)
    InstallationSettings.clear_layout_cache()
    on_exit(&InstallationSettings.clear_layout_cache/0)
    %{user: user}
  end

  defp nav_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#main-nav [id^='nav-']")
    |> LazyHTML.attribute("id")
  end

  test "moving and hiding items, then saving, changes the menu for everyone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/layout")

    assert has_element?(view, "#layout-banner")
    assert has_element?(view, "#layout-up-dashboard[disabled]")

    view |> element("#layout-down-dashboard") |> render_click()
    view |> element("#layout-toggle-bin") |> render_click()
    assert has_element?(view, ~s(#layout-item-bin[data-hidden="true"]))

    assert {:error, {:live_redirect, %{to: "/admin"}}} =
             view |> element("#layout-save") |> render_click()

    {:ok, view, _html} = live(conn, ~p"/invoices")

    assert ["nav-invoices", "nav-dashboard" | _rest] = nav_order(view)
    refute has_element?(view, "#nav-bin")
    assert has_element?(view, "#nav-settings")
  end

  test "Settings can never be hidden", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/layout")

    assert has_element?(view, "#layout-item-settings")
    refute has_element?(view, "#layout-toggle-settings")

    # Even a forged event leaves it shown.
    render_click(view, "layout_toggle", %{"key" => "settings"})
    assert has_element?(view, ~s(#layout-item-settings[data-hidden="false"]))
  end

  test "Cancel saves nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/layout")

    view |> element("#layout-toggle-clients") |> render_click()
    view |> element("#layout-cancel") |> render_click()

    assert InstallationSettings.nav_layout() == []
  end
end
