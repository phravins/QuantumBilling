defmodule QuantumBillingWeb.API.AuthTest do
  @moduledoc """
  Who gets past the front door of `/api/v1`, and what the ones who do not are
  told.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.ApiFixtures

  alias QuantumBilling.ApiKeys
  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBilling.Repo

  defp unauthorized_body(conn) do
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="QuantumBilling API")]
    conn.resp_body
  end

  describe "refused" do
    test "no key, a wrong key, a revoked key and an expired key all get the same 401" do
      {revoked_raw, revoked} = api_key_fixture(["invoices:read"])
      {:ok, _} = ApiKeys.revoke_key(revoked, QuantumBilling.AccountsFixtures.owner_fixture())

      {expired_raw, expired} = api_key_fixture(["invoices:read"])

      expired
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -60))
      |> Repo.update!()

      {live_raw, _key} = api_key_fixture(["invoices:read"])
      # Same shape and length as a real key, one character off.
      wrong =
        String.slice(live_raw, 0..-2//1) <>
          if(String.ends_with?(live_raw, "A"), do: "B", else: "A")

      bodies = [
        build_conn() |> get(~p"/api/v1/invoices") |> unauthorized_body(),
        wrong |> api_conn() |> get(~p"/api/v1/invoices") |> unauthorized_body(),
        "not-a-key" |> api_conn() |> get(~p"/api/v1/invoices") |> unauthorized_body(),
        revoked_raw |> api_conn() |> get(~p"/api/v1/invoices") |> unauthorized_body(),
        expired_raw |> api_conn() |> get(~p"/api/v1/invoices") |> unauthorized_body()
      ]

      # One body for every reason: telling them apart would tell a guesser
      # which guess came close, or that a stolen key was merely revoked.
      assert bodies |> Enum.uniq() |> length() == 1
      assert %{"error" => %{"code" => "unauthorized"}} = Jason.decode!(hd(bodies))
    end

    test "a key sent as anything but a bearer token is refused" do
      {raw, _key} = api_key_fixture(["invoices:read"])

      conn =
        build_conn()
        |> put_req_header("authorization", "Basic " <> Base.encode64(raw <> ":"))
        |> get(~p"/api/v1/invoices")

      assert conn.status == 401
    end

    test "a key in the query string is refused, even a valid one, and the caller is told why" do
      {raw, _key} = api_key_fixture(["invoices:read"])

      for name <- ~w(api_key apikey key token access_token) do
        conn = get(build_conn(), "/api/v1/invoices?#{name}=#{raw}")

        assert %{"error" => %{"code" => "key_in_url", "message" => message}} =
                 json_response(conn, 400)

        assert message =~ "revoke it"
      end
    end

    test "a valid header does not excuse a key also placed in the URL" do
      {raw, _key} = api_key_fixture(["invoices:read"])

      conn = raw |> api_conn() |> get("/api/v1/invoices?api_key=#{raw}")

      assert json_response(conn, 400)["error"]["code"] == "key_in_url"
    end

    test "an unknown path is a 401 to a stranger, so the route table cannot be mapped" do
      assert build_conn() |> get("/api/v1/secret-admin") |> Map.get(:status) == 401
      assert build_conn() |> get("/api/v1/invoices/1") |> Map.get(:status) == 401
    end
  end

  describe "accepted" do
    test "a valid key reaches the API and is recorded as used, with the caller's address" do
      {raw, key} = api_key_fixture(["invoices:read"])

      conn = raw |> api_conn() |> get(~p"/api/v1/invoices")

      assert json_response(conn, 200)["data"] == []
      used = Repo.get!(ApiKey, key.id)
      assert %DateTime{} = used.last_used_at
      assert used.last_used_ip == "127.0.0.1"
    end

    test "an unknown path is a JSON 404 once authenticated, never the HTML page" do
      {raw, _key} = api_key_fixture(["invoices:read"])

      conn = raw |> api_conn() |> get("/api/v1/nothing-here")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "/me says what the key can do, and nothing that would reproduce it" do
      {raw, key} = api_key_fixture(["clients:read", "invoices:read"])

      conn = raw |> api_conn() |> get(~p"/api/v1/me")
      body = json_response(conn, 200)

      assert body["data"]["name"] == key.name
      assert Enum.sort(body["data"]["scopes"]) == ["clients:read", "invoices:read"]
      assert body["data"]["prefix"] == key.prefix
      refute conn.resp_body =~ raw
      refute conn.resp_body =~ Base.encode64(key.hashed_key)
      refute conn.resp_body =~ Base.encode16(key.hashed_key, case: :lower)
    end

    test "the response sets no cookie" do
      {raw, _key} = api_key_fixture(["invoices:read"])

      conn = raw |> api_conn() |> get(~p"/api/v1/me")

      assert conn.status == 200
      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  describe "storage" do
    test "only a hash of the key is stored" do
      {raw, key} = api_key_fixture(["invoices:read"])
      stored = Repo.get!(ApiKey, key.id)

      assert stored.hashed_key == :crypto.hash(:sha256, raw)
      assert String.starts_with?(raw, stored.prefix)
      refute stored.prefix == raw

      # Nothing in the row, read back as text, is the key.
      row = Repo.query!("SELECT * FROM api_keys WHERE id = $1", [key.id])
      refute inspect(row.rows) =~ raw
    end

    test "the key never appears in an inspected struct" do
      {_raw, key} = api_key_fixture(["invoices:read"])

      refute inspect(key) =~ inspect(key.hashed_key)
    end
  end
end
