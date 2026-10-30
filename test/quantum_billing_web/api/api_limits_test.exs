defmodule QuantumBillingWeb.API.LimitsTest do
  @moduledoc """
  Rate limits, and simultaneous retries of one write.

  Not async: the concurrent test needs the sandbox shared with the tasks it
  starts.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import QuantumBilling.ApiFixtures

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  test "writes are limited to 60 a minute per key, with a retry-after" do
    {raw, _key} = api_key_fixture(["clients:write"])
    {other, _key} = api_key_fixture(["clients:write"])

    statuses =
      for _ <- 1..61 do
        # An empty body fails validation cheaply; it still counts as a write.
        raw |> api_conn() |> api_post(~p"/api/v1/clients", %{}) |> Map.get(:status)
      end

    assert Enum.take(statuses, 60) |> Enum.all?(&(&1 == 422))
    assert List.last(statuses) == 429

    limited = raw |> api_conn() |> api_post(~p"/api/v1/clients", %{})
    assert json_response(limited, 429)["error"]["code"] == "rate_limited"
    assert [retry_after] = get_resp_header(limited, "retry-after")
    assert String.to_integer(retry_after) > 0

    # Per key: one integration running hot does not lock out another.
    assert other |> api_conn() |> api_post(~p"/api/v1/clients", %{}) |> Map.get(:status) == 422
  end

  test "reads report their remaining allowance" do
    {raw, _key} = api_key_fixture(["invoices:read"])

    conn = raw |> api_conn() |> get(~p"/api/v1/me")

    assert get_resp_header(conn, "x-ratelimit-limit") == ["600"]
    assert [remaining] = get_resp_header(conn, "x-ratelimit-remaining")
    assert String.to_integer(remaining) < 600
  end

  test "simultaneous retries of one write create exactly one invoice" do
    {raw, _key} = api_key_fixture(["invoices:write"])
    client = client_fixture()
    before = Repo.aggregate(Invoice, :count)

    body = %{
      "client_id" => client.id,
      "invoice_date" => "2026-10-01",
      "place_of_supply" => "Maharashtra (27)",
      "items" => [%{"description" => "Retry storm", "rate" => 100}]
    }

    statuses =
      1..8
      |> Task.async_stream(
        fn _ ->
          raw |> api_conn() |> api_post(~p"/api/v1/invoices", body, "storm") |> Map.get(:status)
        end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert Repo.aggregate(Invoice, :count) == before + 1
    assert Enum.all?(statuses, &(&1 in [201, 409]))
    assert 201 in statuses
  end
end
