defmodule QuantumBillingWeb.API.HttpsTest do
  @moduledoc """
  The API refuses plain http in production rather than redirecting it.

  Not async: it flips the application setting production turns on.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import QuantumBilling.ApiFixtures

  alias QuantumBillingWeb.Plugs.ApiRequireHttps

  setup do
    previous = Application.get_env(:quantum_billing, :api_require_https)
    Application.put_env(:quantum_billing, :api_require_https, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:quantum_billing, :api_require_https),
        else: Application.put_env(:quantum_billing, :api_require_https, previous)
    end)
  end

  test "an http call is refused with 403, not redirected" do
    {raw, _key} = api_key_fixture(["invoices:read"])

    conn = raw |> api_conn() |> get("http://www.example.com/api/v1/me")

    assert %{"error" => %{"code" => "https_required"}} = json_response(conn, 403)
    assert get_resp_header(conn, "location") == []
  end

  test "it is refused before the key is even looked at" do
    {raw, key} = api_key_fixture(["invoices:read"])

    raw |> api_conn() |> get("http://www.example.com/api/v1/me")

    # Not marked as used: the request never got as far as authentication.
    assert QuantumBilling.Repo.get!(QuantumBilling.ApiKeys.ApiKey, key.id).last_used_at == nil
  end

  test "an https call goes through" do
    {raw, _key} = api_key_fixture(["invoices:read"])

    conn = raw |> api_conn() |> get("https://www.example.com/api/v1/me")

    assert json_response(conn, 200)["data"]
  end

  describe "force_ssl in production" do
    # The production endpoint's `force_ssl`, with the exclusion it is
    # configured with: it must leave API calls to the plug above and keep
    # redirecting everything else.
    defp force_ssl do
      Plug.SSL.init(
        rewrite_on: [:x_forwarded_proto],
        exclude: [hosts: ["localhost"], conn: {ApiRequireHttps, :api_request?, []}]
      )
    end

    test "does not redirect an API call" do
      conn =
        Plug.SSL.call(build_conn(:get, "http://quantum.example/api/v1/invoices"), force_ssl())

      refute conn.halted
    end

    test "still redirects the application" do
      conn = Plug.SSL.call(build_conn(:get, "http://quantum.example/invoices"), force_ssl())

      assert conn.halted
      assert conn.status in [301, 307]
    end

    test "and the webhook receiver, which is not under /api/v1" do
      conn =
        Plug.SSL.call(
          build_conn(:post, "http://quantum.example/api/webhooks/razorpay"),
          force_ssl()
        )

      assert conn.halted
    end
  end
end
