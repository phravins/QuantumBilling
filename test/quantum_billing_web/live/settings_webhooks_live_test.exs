defmodule QuantumBillingWeb.SettingsLive.WebhooksTest do
  @moduledoc "The owner-only webhooks page."
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Repo
  alias QuantumBilling.Webhooks
  alias QuantumBilling.Webhooks.{Delivery, Endpoint}

  setup do
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
    :ok
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    test "adds an endpoint and shows its secret once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/webhooks")

      view
      |> form("#webhook-form", %{
        "endpoint" => %{
          "url" => "https://erp.example.test/hooks",
          "description" => "Accounting",
          "events" => ["", "invoice.paid", "client.created"]
        }
      })
      |> render_submit()

      assert has_element?(view, "#new-webhook-secret")
      [secret] = Regex.run(~r/whsec_[A-Za-z0-9_-]+/, render(view))

      endpoint = Repo.get_by!(Endpoint, url: "https://erp.example.test/hooks")
      assert endpoint.secret == secret
      assert Enum.sort(endpoint.events) == ["client.created", "invoice.paid"]

      view |> element("#dismiss-webhook-secret") |> render_click()
      refute render(view) =~ secret

      {:ok, _view, html} = live(conn, ~p"/settings/webhooks")
      refute html =~ secret
      assert html =~ "https://erp.example.test/hooks"
    end

    test "refuses an endpoint with no events, or not https", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/webhooks")

      html =
        view
        |> form("#webhook-form", %{
          "endpoint" => %{"url" => "http://erp.example.test/hooks", "events" => [""]}
        })
        |> render_submit()

      assert html =~ "choose at least one event"
      assert html =~ "https://"
      assert Repo.aggregate(Endpoint, :count) == 0
    end

    test "sends a test, lists the delivery and resends it", %{conn: conn, user: owner} do
      {:ok, endpoint, _secret} =
        Webhooks.create_endpoint(
          %{"url" => "https://erp.example.test/hooks", "events" => ["invoice.created"]},
          owner
        )

      {:ok, view, _html} = live(conn, ~p"/settings/webhooks")

      view |> element("#test-endpoint-#{endpoint.id}") |> render_click()

      delivery = Repo.get_by!(Delivery, endpoint_id: endpoint.id)
      assert delivery.event_type == "webhook.test"
      assert has_element?(view, "#delivery-#{delivery.id}", "succeeded")

      view |> element("#resend-delivery-#{delivery.id}") |> render_click()
      assert Repo.get!(Delivery, delivery.id).attempts == 2
    end

    test "rotates, switches off and on, and removes", %{conn: conn, user: owner} do
      {:ok, endpoint, secret} =
        Webhooks.create_endpoint(
          %{"url" => "https://erp.example.test/hooks", "events" => ["invoice.created"]},
          owner
        )

      {:ok, view, _html} = live(conn, ~p"/settings/webhooks")

      view |> element("#rotate-endpoint-#{endpoint.id}") |> render_click()
      assert has_element?(view, "#new-webhook-secret")
      refute Repo.get!(Endpoint, endpoint.id).secret == secret

      view |> element("#toggle-endpoint-#{endpoint.id}") |> render_click()
      refute Repo.get!(Endpoint, endpoint.id).enabled
      assert has_element?(view, "#endpoint-#{endpoint.id}", "Switched off by an owner")

      view |> element("#toggle-endpoint-#{endpoint.id}") |> render_click()
      assert Repo.get!(Endpoint, endpoint.id).enabled

      view |> element("#delete-endpoint-#{endpoint.id}") |> render_click()
      refute Repo.get(Endpoint, endpoint.id)
    end

    test "the settings menu links to it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ ~s(href="/settings/webhooks")
    end
  end

  describe "as staff" do
    setup :register_and_log_in_user

    test "the page is refused", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/settings/webhooks")
    end

    test "the menu does not offer it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ ~s(href="/settings/webhooks")
    end
  end
end
