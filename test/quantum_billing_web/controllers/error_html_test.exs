defmodule QuantumBillingWeb.ErrorHTMLTest do
  use QuantumBillingWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  describe "templates" do
    test "renders a branded 404.html" do
      html = render_to_string(QuantumBillingWeb.ErrorHTML, "404", "html", [])

      assert html =~ "Page not found"
      assert html =~ "QuantumBilling"
      assert html =~ "<!DOCTYPE html>"
      # Self-contained: it carries its own stylesheet, since render_errors is
      # configured `layout: false`.
      assert html =~ "/assets/css/app.css"
    end

    test "renders a branded 500.html" do
      html = render_to_string(QuantumBillingWeb.ErrorHTML, "500", "html", [])

      assert html =~ "Something went wrong"
      assert html =~ "QuantumBilling"
    end

    test "falls back to the plain status message for other statuses" do
      assert render_to_string(QuantumBillingWeb.ErrorHTML, "403", "html", []) == "Forbidden"
    end
  end

  describe "unknown routes" do
    test "responds 404 instead of raising NoRouteError", %{conn: conn} do
      conn = get(conn, "/definitely-not-a-route")

      assert conn.status == 404
      assert html_response(conn, 404) =~ "Page not found"
    end

    test "never discloses the router's contents", %{conn: conn} do
      # The exact URL that produced the debug route listing.
      body = conn |> get("/users/log") |> html_response(404)

      # The debug page's route table — the whole point of the catch-all.
      refute body =~ "Available routes"
      refute body =~ "NoRouteError"
      refute body =~ "LiveDashboard"
      refute body =~ "/dev/"

      # No route paths from the listing leak either.
      refute body =~ ~p"/e-way-bills"
      refute body =~ ~p"/invoices"
      refute body =~ ~p"/clients"

      # Deliberately NOT asserted: the absence of "QuantumBillingWeb.". In dev,
      # `debug_heex_annotations` (config/dev.exs) wraps every component in an
      # HTML comment naming its module and source file — on this page and every
      # other one. Asserting it here would pass only because the test env turns
      # annotations off, which is false confidence rather than a real guarantee.
    end

    test "handles non-GET verbs too", %{conn: conn} do
      assert conn |> post("/definitely-not-a-route") |> html_response(404) =~ "Page not found"
    end

    test "offers no navigation away from the page", %{conn: conn} do
      body = conn |> get("/definitely-not-a-route") |> html_response(404)

      refute body =~ "Back to dashboard"
      refute body =~ "Go to sign in"
      refute body =~ "<a "
    end
  end

  describe "unknown routes when signed in" do
    setup :register_and_log_in_user

    test "look the same as when signed out", %{conn: conn} do
      body = conn |> get("/definitely-not-a-route") |> html_response(404)

      assert body =~ "Page not found"
      refute body =~ "Back to dashboard"
    end
  end

  describe "real routes" do
    test "are still reachable — the catch-all does not shadow them", %{conn: conn} do
      # Signed out, a real protected route redirects rather than 404s.
      conn = get(conn, ~p"/dashboard")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "the sign-in page still renders", %{conn: conn} do
      assert conn |> get(~p"/users/log-in") |> html_response(200) =~ "Welcome back"
    end
  end
end
