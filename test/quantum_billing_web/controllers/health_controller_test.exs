defmodule QuantumBillingWeb.HealthControllerTest do
  use QuantumBillingWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias QuantumBillingWeb.HealthController

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

    test "does not publish the application version", %{conn: conn} do
      body = conn |> get(~p"/health") |> json_response(200)

      # A version number on a public endpoint is a lookup key for known
      # vulnerabilities in that release.
      refute Map.has_key?(body, "version")
    end
  end

  describe "the failure body" do
    # The real messages Postgrex produces. The first is word for word what this
    # test environment printed when its database password was not yet set.
    @driver_errors [
      ~s|FATAL 28P01 (invalid_password) password authentication failed for user "postgres"|,
      ~s|tcp connect (db.internal.example:5432): connection refused - :econnrefused|,
      ~s|FATAL 3D000 (invalid_catalog_name) database "quantum_billing_prod" does not exist|
    ]

    test "says only that the database is unavailable" do
      for reason <- @driver_errors do
        {{status, body}, _log} = with_log(fn -> HealthController.payload({:error, reason}) end)

        assert status == 503
        assert body == %{status: "error", database: "unavailable"}
      end
    end

    test "carries no part of the driver's message" do
      for reason <- @driver_errors do
        {{_status, body}, _log} = with_log(fn -> HealthController.payload({:error, reason}) end)
        encoded = Jason.encode!(body)

        # This endpoint answers anyone. A username, a hostname or a database
        # name in it is a gift to whoever is probing.
        for fragment <- ["postgres", "password", "db.internal", "5432", "quantum_billing_prod"] do
          refute encoded =~ fragment, "the public body leaked #{inspect(fragment)}"
        end
      end
    end

    test "puts the detail in the log, where operators look" do
      {_result, log} =
        with_log(fn -> HealthController.payload({:error, hd(@driver_errors)}) end)

      assert log =~ "password authentication failed"
    end
  end
end
