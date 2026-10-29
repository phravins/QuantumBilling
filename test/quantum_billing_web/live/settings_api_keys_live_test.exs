defmodule QuantumBillingWeb.SettingsLive.ApiKeysTest do
  @moduledoc """
  The owner-only API keys page: issuing a key, seeing it once, revoking it.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import QuantumBilling.ApiFixtures

  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Repo

  describe "as an owner" do
    setup :register_and_log_in_owner

    test "creates a key, shows it once, and the key works", %{conn: conn, user: owner} do
      {:ok, view, _html} = live(conn, ~p"/settings/api-keys")

      view
      |> form("#api-key-form", %{
        "api_key" => %{
          "name" => "Tally sync",
          "expires_in" => "30",
          "scopes" => ["", "invoices:read", "clients:read"]
        }
      })
      |> render_submit()

      assert has_element?(view, "#new-api-key")
      raw = view |> element("#new-api-key-value") |> render() |> extract_key()

      key = Repo.get_by!(ApiKey, name: "Tally sync")
      assert Enum.sort(key.scopes) == ["clients:read", "invoices:read"]
      assert key.created_by_id == owner.id
      assert DateTime.diff(key.expires_at, DateTime.utc_now(), :day) in 29..30

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> raw)
             |> get(~p"/api/v1/me")
             |> json_response(200)
             |> get_in(["data", "name"]) == "Tally sync"

      assert Repo.exists?(
               from l in AuditLog, where: l.action == "api_key_created" and l.user_id == ^owner.id
             )

      # Dismissed, the key is gone from the page and cannot be brought back.
      view |> element("#dismiss-new-api-key") |> render_click()
      refute has_element?(view, "#new-api-key")
      refute render(view) =~ raw

      {:ok, _view, html} = live(conn, ~p"/settings/api-keys")
      refute html =~ raw
      assert html =~ key.prefix
    end

    test "a key needs at least one permission", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/api-keys")

      html =
        view
        |> form("#api-key-form", %{
          "api_key" => %{"name" => "No scopes", "expires_in" => "90", "scopes" => [""]}
        })
        |> render_submit()

      refute has_element?(view, "#new-api-key")
      assert html =~ "choose at least one permission"
      assert Repo.aggregate(ApiKey, :count) == 0
    end

    test "a key needs a name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/api-keys")

      view
      |> form("#api-key-form", %{
        "api_key" => %{"name" => "  ", "expires_in" => "90", "scopes" => ["invoices:read"]}
      })
      |> render_submit()

      refute has_element?(view, "#new-api-key")
      assert Repo.aggregate(ApiKey, :count) == 0
    end

    test "revokes a key, which stops working at once", %{conn: conn, user: owner} do
      {raw, key} = api_key_fixture(["invoices:read"], %{owner: owner})
      {:ok, view, _html} = live(conn, ~p"/settings/api-keys")

      view |> element("#revoke-api-key-#{key.id}") |> render_click()

      assert %DateTime{} = Repo.get!(ApiKey, key.id).revoked_at
      refute has_element?(view, "#revoke-api-key-#{key.id}")
      assert raw |> api_conn() |> get(~p"/api/v1/me") |> Map.get(:status) == 401
    end

    test "the settings menu links to it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ ~s(href="/settings/api-keys")
    end
  end

  describe "as staff" do
    setup :register_and_log_in_user

    test "the page is refused", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/settings/api-keys")
    end

    test "the menu does not offer it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ ~s(href="/settings/api-keys")
    end
  end

  test "signed out, the page redirects to log in" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/settings/api-keys")
  end

  defp extract_key(html) do
    [key] = Regex.run(~r/qb_live_[A-Za-z0-9_-]+/, html)
    key
  end
end
