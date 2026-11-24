defmodule QuantumBilling.AuditActorTest do
  @moduledoc """
  Who an audit entry names: the member, API key or link the request came
  through, set once per request rather than passed to every context call.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.ApiFixtures, only: [api_key_fixture: 1, api_conn: 1, api_post: 3]

  alias QuantumBilling.AccountsFixtures
  alias QuantumBilling.Audit

  setup do
    Audit.clear_actor()
    :ok
  end

  defp entries(action), do: Enum.filter(Audit.list_audit_logs(), &(&1.action == action))

  describe "log_event/4" do
    test "names the process's actor, and keeps their name for after they leave" do
      user = AccountsFixtures.user_fixture()
      Audit.put_actor(%{user_id: user.id, ip_address: "203.0.113.9", name: "Meera Iyer"})

      {:ok, log} = Audit.log_event(:client_created, "Client", 1)

      assert log.user_id == user.id
      assert log.ip_address == "203.0.113.9"
      assert log.details["actor"] == "Meera Iyer"
    end

    test "an explicit member wins, without borrowing the actor's address or name" do
      actor = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      Audit.put_actor(%{user_id: actor.id, ip_address: "203.0.113.9", name: "Meera Iyer"})

      {:ok, log} = Audit.log_event(:bin_client, "Client", 1, user_id: other.id)

      assert log.user_id == other.id
      assert log.ip_address == nil
      refute Map.has_key?(log.details, "actor")
    end

    test "with no actor the entry is the system's" do
      {:ok, log} = Audit.log_event(:invoice_created, "Invoice", 1)

      assert log.user_id == nil
      assert log.api_key_id == nil
      assert log.ip_address == nil
    end

    test "a client acting through a shared link is marked as such" do
      Audit.put_actor(%{via: "public_link", ip_address: "198.51.100.4"})

      {:ok, log} = Audit.log_event(:payment_received, "Invoice", 1)

      assert log.details["via"] == "public_link"
      assert log.ip_address == "198.51.100.4"
    end
  end

  describe "requests" do
    test "each request gets its own actor, and the caller's is put back afterwards", %{
      conn: conn
    } do
      previous = Audit.put_actor(%{via: "razorpay"})

      conn |> get(~p"/users/log-in") |> html_response(200)

      assert Audit.actor() == previous
    end

    test "an API write names the key and the caller's address, once" do
      {raw, key} = api_key_fixture(["clients:write"])

      body = %{
        "type" => "Unregistered",
        "name" => "Northwind Traders",
        "phone" => "9876543210",
        "billing_address" => %{
          "line1" => "7 Harbour Road",
          "city" => "Kochi",
          "state" => "Kerala (32)",
          "pin" => "682001"
        }
      }

      id = raw |> api_conn() |> api_post(~p"/api/v1/clients", body) |> json_response(201)
      id = to_string(id["data"]["id"])

      assert [log] = Enum.filter(entries("client_created"), &(&1.resource_id == id))
      assert log.api_key_id == key.id
      assert log.user_id == nil
      assert log.ip_address == "127.0.0.1"
      assert log.details["actor"] == key.name
    end
  end

  describe "LiveView" do
    setup :register_and_log_in_user

    test "an action on a page names the member and their address", %{conn: conn, user: user} do
      # The socket's connect info is the request's peer, as it is behind no proxy.
      conn =
        Plug.Test.put_peer_data(conn, %{address: {203, 0, 113, 7}, port: 4000, ssl_cert: nil})

      {:ok, view, _html} = live(conn, ~p"/clients/new")

      assert {:error, {:live_redirect, %{to: "/clients"}}} =
               view
               |> form("#client-form", %{
                 "client" => %{
                   "client_type" => "Unregistered",
                   "name" => "Live Traders",
                   "email" => "accounts@live.example",
                   "phone" => "9876543210",
                   "billing_line1" => "1 Main Road",
                   "billing_city" => "Pune",
                   "billing_state" => "Maharashtra (27)",
                   "billing_pin" => "411001"
                 }
               })
               |> render_submit()

      assert [log] =
               Enum.filter(entries("client_created"), &(&1.details["label"] == "Live Traders"))

      assert log.user_id == user.id
      assert log.ip_address == "203.0.113.7"
    end
  end
end
