defmodule QuantumBillingWeb.CoreComponentsTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  describe "the connection toasts" do
    # Hidden until `phx-disconnected`. A broken attribute would drop `hidden` and
    # `class` and leave them visible in the page flow.
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

  describe "input debounce" do
    # A form re-rendered on every keystroke made errors flicker and pages shake.
    defp debounce(attrs) do
      (&QuantumBillingWeb.CoreComponents.input/1)
      |> render_component(Map.merge(%{name: "field", value: "", id: "field"}, attrs))
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#field")
      |> LazyHTML.attribute("phx-debounce")
    end

    test "typed fields wait for a pause by default" do
      for type <- ~w(text email tel url password search number textarea) do
        assert debounce(%{type: type}) == ["300"], "#{type} is not debounced"
      end
    end

    test "an explicit value wins, and nil turns it off" do
      assert debounce(%{type: "text", "phx-debounce": "blur"}) == ["blur"]
      assert debounce(%{type: "text", "phx-debounce": nil}) == []
    end

    test "choices still send at once" do
      assert debounce(%{type: "select", options: ["a", "b"]}) == []
      assert debounce(%{type: "date"}) == []
    end
  end
end
