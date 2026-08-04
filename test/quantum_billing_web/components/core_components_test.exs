defmodule QuantumBillingWeb.CoreComponentsTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  describe "the connection toasts" do
    # These ship hidden and are revealed by `phx-disconnected` only. An
    # attribute that breaks its own quoting swallows everything after it in the
    # tag, so `hidden` and `class` vanish and the toasts render unstyled in the
    # page flow — two spinners stuck at the bottom of every screen, adding
    # height and a second scrollbar.
    test "stay hidden and keep their attributes intact", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      for id <- ["client-error", "server-error"] do
        assert has_element?(view, "##{id}[hidden]"),
               "##{id} lost its hidden attribute"

        assert has_element?(view, "##{id}.toast.toast-top.toast-end"),
               "##{id} lost its toast positioning classes"

        assert has_element?(view, "##{id}[phx-connected][phx-disconnected]"),
               "##{id} lost the bindings that show and hide it"
      end
    end

    # The dismissal key must be the plain flash string. The connection toasts
    # carry markup as their body, which has no business in an attribute.
    test "carry no dismissal key, because they have no plain-text message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      refute has_element?(view, "#client-error[data-msg]")
      refute has_element?(view, "#server-error[data-msg]")
    end
  end

  describe "a real flash" do
    test "renders its message and carries it as the dismissal key", %{conn: _conn} do
      # Bounced off a protected page, which sets a genuine error flash.
      conn = get(build_conn(), ~p"/invoices")
      {:ok, view, html} = live(conn |> recycle() |> get(~p"/users/log-in"))

      assert html =~ "You must log in to access this page."

      assert has_element?(
               view,
               ~s(#flash-error[data-msg="You must log in to access this page."])
             )
    end
  end
end
