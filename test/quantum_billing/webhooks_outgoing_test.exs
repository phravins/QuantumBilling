defmodule QuantumBilling.WebhooksOutgoingTest do
  @moduledoc """
  Outgoing webhooks, v2: what is sent, how it is signed, how failures are
  handled, and which events the rest of the application publishes.

  Requests are intercepted with `Req.Test`, so the assertions are on the bytes
  and headers that would really have gone over the wire. Oban runs inline in
  tests, so the first attempt happens inside `publish/3`; later attempts are
  run by calling the worker directly with the attempt number.
  """
  use QuantumBilling.DataCase, async: false

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Webhooks
  alias QuantumBilling.Webhooks.{Delivery, Endpoint}
  alias QuantumBilling.Workers.{WebhookDeliveryWorker, WebhookDispatchWorker}

  setup do
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)
    Req.Test.set_req_test_to_shared()

    # Until a test says otherwise, every endpoint answers 200 and reports what
    # it received.
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:received, conn.host, Map.new(conn.req_headers), body})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    %{owner: owner_fixture()}
  end

  defp endpoint(owner, attrs \\ %{}) do
    {:ok, endpoint, secret} =
      Webhooks.create_endpoint(
        Map.merge(
          %{"url" => "https://erp.example.test/hooks", "events" => ["invoice.created"]},
          attrs
        ),
        owner
      )

    {endpoint, secret}
  end

  defp answer(status) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:received, conn.host, Map.new(conn.req_headers), body})
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp attempt(delivery, attempt) do
    WebhookDeliveryWorker.perform(%Oban.Job{
      args: %{"delivery_id" => delivery.id},
      attempt: attempt,
      max_attempts: 9
    })
  end

  defp delivery_for(endpoint), do: Repo.get_by!(Delivery, endpoint_id: endpoint.id)

  describe "publishing" do
    test "is a no-op when nothing is subscribed" do
      assert {:ok, nil} = Webhooks.publish("invoice.created", 1)
      assert Repo.aggregate(Delivery, :count) == 0
      refute_received {:received, _, _, _}
    end

    test "goes to enabled, subscribed endpoints only, under one event id", %{owner: owner} do
      {a, _} = endpoint(owner, %{"url" => "https://a.example.test/h"})
      {b, _} = endpoint(owner, %{"url" => "https://b.example.test/h"})

      {_unsubscribed, _} =
        endpoint(owner, %{"url" => "https://c.example.test/h", "events" => ["client.created"]})

      {off, _} = endpoint(owner, %{"url" => "https://d.example.test/h"})
      {:ok, _} = Webhooks.set_enabled(off, false, owner)

      assert {:ok, "evt_" <> _ = event_id} = Webhooks.publish("invoice.created", 42)

      deliveries = Repo.all(Delivery)
      assert deliveries |> Enum.map(& &1.endpoint_id) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert Enum.all?(deliveries, &(&1.event_id == event_id))
    end

    test "a thin event carries the id, the type and the record, nothing more", %{owner: owner} do
      endpoint(owner)

      {:ok, event_id} =
        Webhooks.publish("invoice.created", 42, %{"client_name" => "Not for thin"})

      assert_received {:received, _host, _headers, body}

      assert %{
               "id" => ^event_id,
               "type" => "invoice.created",
               "created_at" => _,
               "data" => %{"object" => "invoice", "id" => 42}
             } = decoded = Jason.decode!(body)

      assert map_size(decoded) == 4
      refute body =~ "Not for thin"
    end
  end

  describe "signing" do
    test "the signature covers the timestamp and the exact body", %{owner: owner} do
      {_endpoint, secret} = endpoint(owner)

      {:ok, event_id} = Webhooks.publish("invoice.created", 7)

      assert_received {:received, _host, headers, body}
      assert headers["x-quantumbilling-event-id"] == event_id
      assert headers["x-quantumbilling-event"] == "invoice.created"
      assert "t=" <> _ = signature = headers["x-quantumbilling-signature"]

      assert Webhooks.verify_signature(signature, body, secret)
      refute Webhooks.verify_signature(signature, body <> " ", secret)
      refute Webhooks.verify_signature(signature, body, "whsec_wrong")
    end

    test "a signature is refused once it is more than five minutes old", %{owner: owner} do
      {endpoint, secret} = endpoint(owner)
      body = ~s({"id":"evt_x"})
      old = System.system_time(:second) - 301

      header = Webhooks.signature_header(endpoint, body, old)

      refute Webhooks.verify_signature(header, body, secret)
      assert Webhooks.verify_signature(header, body, secret, old)
    end

    test "after rotation both secrets sign for a day, then only the new one", %{owner: owner} do
      {endpoint, old_secret} = endpoint(owner)
      {:ok, rotated, new_secret} = Webhooks.rotate_secret(endpoint, owner)
      refute new_secret == old_secret

      now = System.system_time(:second)
      header = Webhooks.signature_header(rotated, "body", now)

      assert length(String.split(header, ",")) == 3
      assert Webhooks.verify_signature(header, "body", new_secret, now)
      assert Webhooks.verify_signature(header, "body", old_secret, now)

      expired =
        rotated
        |> Ecto.Changeset.change(
          previous_secret_expires_at: DateTime.add(DateTime.utc_now(:second), -1)
        )
        |> Repo.update!()

      header = Webhooks.signature_header(expired, "body", now)
      assert Webhooks.verify_signature(header, "body", new_secret, now)
      refute Webhooks.verify_signature(header, "body", old_secret, now)
    end

    test "the secret is generated, stored encrypted and never inspected", %{owner: owner} do
      {endpoint, secret} = endpoint(owner)

      assert "whsec_" <> _ = secret
      refute inspect(endpoint) =~ secret

      %{rows: [[stored]]} =
        Repo.query!("SELECT secret FROM biz_1.webhook_endpoints WHERE id = $1", [endpoint.id])

      refute stored =~ secret
      assert Repo.get!(Endpoint, endpoint.id).secret == secret
    end
  end

  describe "delivery" do
    test "connects to the checked address, under the endpoint's name", %{owner: owner} do
      endpoint(owner)

      Webhooks.publish("invoice.created", 1)

      # Req.Test sees the URL Req was handed: the pinned address.
      assert_received {:received, "203.0.113.10", _headers, _body}
    end

    test "a retry sends the same bytes under the same event id, with a fresh signature", %{
      owner: owner
    } do
      {endpoint, _} = endpoint(owner)
      answer(503)

      {:ok, event_id} = Webhooks.publish("invoice.created", 9)
      assert_received {:received, _, first_headers, first_body}
      assert delivery_for(endpoint).status == "pending"

      answer(200)
      assert :ok = attempt(delivery_for(endpoint), 2)
      assert_received {:received, _, second_headers, second_body}

      assert second_body == first_body
      assert second_headers["x-quantumbilling-event-id"] == event_id
      assert first_headers["x-quantumbilling-event-id"] == event_id

      delivery = delivery_for(endpoint)
      assert delivery.status == "succeeded"
      assert delivery.attempts == 2
    end

    test "a refusal (4xx) fails at once; 408 and 429 are retried", %{owner: owner} do
      {endpoint, _} = endpoint(owner)
      answer(422)

      Webhooks.publish("invoice.created", 1)
      assert %Delivery{status: "failed", last_status_code: 422} = delivery_for(endpoint)

      for status <- [408, 429] do
        Repo.delete_all(Delivery)
        answer(status)
        Webhooks.publish("invoice.created", 1)
        assert %Delivery{status: "pending"} = delivery_for(endpoint)
      end
    end

    test "the last attempt gives up and counts against the endpoint", %{owner: owner} do
      {endpoint, _} = endpoint(owner)
      answer(500)

      Webhooks.publish("invoice.created", 1)
      assert :discard = attempt(delivery_for(endpoint), 9)

      assert %Delivery{status: "failed", last_error: "Gave up: HTTP 500"} = delivery_for(endpoint)
      assert Repo.get!(Endpoint, endpoint.id).consecutive_failures == 1
    end

    test "410 Gone switches the endpoint off and tells the owners", %{owner: owner} do
      {endpoint, _} = endpoint(owner)
      answer(410)

      Webhooks.publish("invoice.created", 1)

      endpoint = Repo.get!(Endpoint, endpoint.id)
      refute endpoint.enabled
      assert endpoint.disabled_reason =~ "410"

      assert Repo.exists?(
               from n in QuantumBilling.Notifications.Notification,
                 where: n.title == "Webhook endpoint switched off"
             )
    end

    test "ten failed deliveries in a row switch the endpoint off; a success resets the count", %{
      owner: owner
    } do
      {endpoint, _} = endpoint(owner)
      answer(400)

      for id <- 1..9, do: Webhooks.publish("invoice.created", id)
      assert Repo.get!(Endpoint, endpoint.id).consecutive_failures == 9

      answer(200)
      Webhooks.publish("invoice.created", 10)
      assert Repo.get!(Endpoint, endpoint.id).consecutive_failures == 0

      answer(400)
      for id <- 11..20, do: Webhooks.publish("invoice.created", id)

      endpoint = Repo.get!(Endpoint, endpoint.id)
      refute endpoint.enabled
      assert endpoint.disabled_reason =~ "10 deliveries"
    end

    test "a delivery queued before the endpoint was switched off is not sent", %{owner: owner} do
      {endpoint, _} = endpoint(owner)
      answer(503)
      Webhooks.publish("invoice.created", 1)
      assert_received {:received, _, _, _}

      {:ok, _} = Webhooks.set_enabled(endpoint, false, owner)
      assert :ok = attempt(delivery_for(endpoint), 2)

      refute_received {:received, _, _, _}
      assert delivery_for(endpoint).status == "cancelled"
    end

    test "a test event goes even to a switched-off endpoint", %{owner: owner} do
      {endpoint, _} = endpoint(owner)
      {:ok, endpoint} = Webhooks.set_enabled(endpoint, false, owner)

      assert {:ok, %Delivery{event_type: "webhook.test"}} = Webhooks.send_test(endpoint)

      assert_received {:received, _, headers, body}
      assert headers["x-quantumbilling-event"] == "webhook.test"
      assert Jason.decode!(body)["type"] == "webhook.test"
    end

    test "a resend repeats the event id and body", %{owner: owner} do
      {endpoint, _} = endpoint(owner)
      {:ok, event_id} = Webhooks.publish("invoice.created", 3)
      assert_received {:received, _, _, first_body}

      {:ok, _} = Webhooks.resend(delivery_for(endpoint))

      assert_received {:received, _, headers, second_body}
      assert headers["x-quantumbilling-event-id"] == event_id
      assert second_body == first_body
    end

    test "a name that now resolves inside the network is never connected to", %{owner: owner} do
      {endpoint, _} = endpoint(owner, %{"url" => "https://turncoat.example.test/h"})
      QuantumBilling.FakeDNS.put("turncoat.example.test", [{169, 254, 169, 254}])

      Webhooks.publish("invoice.created", 1)

      refute_received {:received, _, _, _}
      assert %Delivery{status: "failed", last_error: "Refused: " <> _} = delivery_for(endpoint)
    end

    test "nothing the receiver answered is stored", %{owner: owner} do
      {endpoint, _} = endpoint(owner)

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "stack trace with SECRET_FROM_RECEIVER")
      end)

      Webhooks.publish("invoice.created", 1)

      refute inspect(delivery_for(endpoint)) =~ "SECRET_FROM_RECEIVER"
    end
  end

  describe "the legacy format" do
    defp legacy_endpoint(secret) do
      Repo.insert!(%Endpoint{
        url: "https://old.example.test/hooks",
        events: ["invoice.created", "invoice.paid"],
        format: "legacy",
        secret: secret
      })
    end

    test "keeps the body and signature its receiver was written for, plus an id" do
      legacy_endpoint("whsec_old")

      {:ok, event_id} =
        Webhooks.publish("invoice.created", 5, %{"invoice_id" => 5, "invoice_number" => "INV-5"})

      assert_received {:received, _, headers, body}

      assert %{
               "id" => ^event_id,
               "event" => "invoice.created",
               "payload" => %{"invoice_id" => 5, "invoice_number" => "INV-5"},
               "sent_at" => _
             } = Jason.decode!(body)

      assert headers["x-quantumbilling-signature"] == Webhooks.sign(body, "whsec_old")
      assert Webhooks.valid_signature?(body, headers["x-quantumbilling-signature"], "whsec_old")
    end

    test "rotating its secret moves it to the current format", %{owner: owner} do
      endpoint = legacy_endpoint("whsec_old")

      {:ok, rotated, _secret} = Webhooks.rotate_secret(endpoint, owner)

      assert rotated.format == "thin"
    end

    test "a job the old worker queued before the upgrade is delivered, not lost" do
      legacy_endpoint("whsec_old")

      assert :ok =
               WebhookDispatchWorker.perform(%Oban.Job{
                 args: %{
                   "event" => "invoice.paid",
                   "payload" => %{"invoice_id" => 8, "amount" => 1180}
                 },
                 attempt: 1,
                 max_attempts: 3
               })

      assert_received {:received, _, _, body}
      assert %{"event" => "invoice.paid", "payload" => %{"amount" => 1180}} = Jason.decode!(body)
    end
  end

  describe "endpoints an owner may add" do
    test "refuses plain http, inside addresses, credentials in the URL, and no events", %{
      owner: owner
    } do
      for {attrs, field} <- [
            {%{"url" => "http://erp.example.test/h"}, :url},
            {%{"url" => "https://169.254.169.254/latest"}, :url},
            {%{"url" => "https://10.0.0.5/h"}, :url},
            {%{"url" => "https://user:pass@erp.example.test/h"}, :url},
            {%{"events" => []}, :events},
            {%{"events" => ["invoice.deleted_forever"]}, :events}
          ] do
        attrs =
          Map.merge(
            %{"url" => "https://erp.example.test/h", "events" => ["invoice.created"]},
            attrs
          )

        assert {:error, changeset} = Webhooks.create_endpoint(attrs, owner),
               "#{inspect(attrs)} was accepted"

        assert Keyword.has_key?(changeset.errors, field)
      end
    end

    test "adding, rotating, switching and removing are audited", %{owner: owner} do
      {endpoint, _} = endpoint(owner)
      {:ok, endpoint, _} = Webhooks.rotate_secret(endpoint, owner)
      {:ok, endpoint} = Webhooks.set_enabled(endpoint, false, owner)
      {:ok, _} = Webhooks.delete_endpoint(endpoint, owner)

      actions =
        Repo.all(
          from l in QuantumBilling.Audit.AuditLog,
            where: l.resource_type == "WebhookEndpoint" and l.user_id == ^owner.id,
            select: l.action
        )

      for action <-
            ~w(webhook_endpoint_created webhook_secret_rotated webhook_endpoint_disabled webhook_endpoint_deleted) do
        assert action in actions
      end
    end
  end

  describe "what the application publishes" do
    setup %{owner: owner} do
      {endpoint, _} = endpoint(owner, %{"events" => Webhooks.event_types()})
      %{endpoint: endpoint}
    end

    defp published_types do
      Repo.all(from d in Delivery, order_by: d.id, select: d.event_type)
    end

    test "invoices: created and updated" do
      {:ok, client} =
        QuantumBilling.Clients.create_client(%{
          "client_type" => "Unregistered",
          "name" => "Published Co",
          "phone" => "9876543210",
          "billing_line1" => "1 Road",
          "billing_city" => "Mumbai",
          "billing_state" => "Maharashtra (27)",
          "billing_pin" => "400001"
        })

      {:ok, invoice} =
        QuantumBilling.Invoices.create_invoice(%{
          "client_id" => client.id,
          "client_name" => client.name,
          "invoice_date" => "2026-10-01",
          "place_of_supply" => "Maharashtra (27)",
          "items" => %{"0" => %{"description" => "Work", "rate" => "100"}}
        })

      {:ok, _} = QuantumBilling.Invoices.update_invoice(invoice, %{"remarks" => "edited"})

      assert published_types() == ["client.created", "invoice.created", "invoice.updated"]
    end

    test "every promised event type has a publisher" do
      # Grep-level check: each type in the catalogue is published somewhere in
      # lib, so Settings never offers an event that is never sent.
      sources =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.map_join("\n", &File.read!/1)

      for type <- Webhooks.event_types() do
        assert sources =~ ~s(Webhooks.publish("#{type}"), "nothing publishes #{type}"
      end
    end
  end
end
