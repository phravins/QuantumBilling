defmodule QuantumBillingWeb.HealthControllerTest do
  use QuantumBillingWeb.ConnCase, async: true

  describe "GET /health" do
    test "answers 200 while the database is reachable", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert %{"status" => "ok", "database" => "ok"} = json_response(conn, 200)
    end

    # The catch-all at the bottom of the router answers anything unmatched with
    # the branded 404 page. A probe that gets HTML back is a probe pointed at
    # the wrong thing, so assert on the content type as well as the body.
    test "is JSON, not the branded 404 page", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    end

    # No session, no CSRF, no current scope: the probe must answer identically
    # signed out, which is how it behaves inside a container.
    test "needs no session", %{conn: _conn} do
      conn = get(build_conn(), ~p"/health")

      assert json_response(conn, 200)["status"] == "ok"
    end
  end
end
