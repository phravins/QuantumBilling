defmodule QuantumBilling.WebhooksTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Settings
  alias QuantumBilling.Webhooks

  describe "claim/3" do
    test "the first caller gets the event and the second is told it is a duplicate" do
      assert {:ok, event} =
               Webhooks.claim("razorpay", "evt_1", %{
                 event_type: "payment.captured",
                 payload: %{"amount" => 100}
               })

      assert event.provider == "razorpay"
      assert event.event_type == "payment.captured"

      assert {:duplicate, existing} = Webhooks.claim("razorpay", "evt_1", %{})
      assert existing.id == event.id
    end

    test "the same id from a different provider is a different event" do
      assert {:ok, _} = Webhooks.claim("razorpay", "evt_shared", %{})
      assert {:ok, _} = Webhooks.claim("stripe", "evt_shared", %{})
    end

    test "records how an event turned out" do
      {:ok, event} = Webhooks.claim("razorpay", "evt_failed", %{})

      assert {:ok, finished} = Webhooks.finish(event, "failed", "invoice not found")
      assert finished.status == "failed"
      assert finished.error == "invoice not found"
    end
  end

  describe "signatures" do
    test "a signature verifies against the exact bytes that were signed" do
      body = ~s({"event":"invoice.created","payload":{"invoice_number":"INV-0001"}})
      signature = Webhooks.sign(body, "shhh")

      assert String.starts_with?(signature, "sha256=")
      assert Webhooks.valid_signature?(body, signature, "shhh")
    end

    test "a changed body, key or signature does not verify" do
      body = ~s({"amount":100})
      signature = Webhooks.sign(body, "shhh")

      refute Webhooks.valid_signature?(~s({"amount":1000}), signature, "shhh")
      refute Webhooks.valid_signature?(body, signature, "other-key")
      refute Webhooks.valid_signature?(body, "sha256=deadbeef", "shhh")
      refute Webhooks.valid_signature?(body, nil, "shhh")
    end

    test "re-encoded JSON does not verify, which is why the raw body is kept" do
      payload = %{"a" => 1, "b" => 2}
      signature = Webhooks.sign(~s({"a": 1, "b": 2}), "shhh")

      refute Webhooks.valid_signature?(Jason.encode!(payload), signature, "shhh")
    end
  end

  describe "dispatch/2" do
    test "is a no-op when the organisation has no endpoint" do
      assert {:ok, :not_configured} = Webhooks.dispatch("invoice.created", %{id: 1})
    end

    test "queues a delivery when an endpoint is configured" do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          # A reserved TLD, so nothing is reached: it does not resolve, the
          # delivery fails locally, and no request leaves this machine.
          %{"webhook_url" => "https://hooks.example.test/hooks", "webhook_secret" => "whsec_test"},
          :integrations
        )

      assert {:ok, %Oban.Job{} = job} = Webhooks.dispatch("invoice.created", %{id: 1})
      assert job.args["event"] == "invoice.created"
    end
  end

  describe "the webhook endpoint a user is allowed to set" do
    test "refuses the addresses that make this server a weapon" do
      # This is the one address in the application that a user supplies and the
      # server then opens a connection to. Accepting any syntactically valid
      # host meant accepting the cloud metadata service and everything else
      # inside the deployment's own network.
      refused = [
        "http://169.254.169.254/latest/meta-data/",
        "http://127.0.0.1:5432/",
        "http://localhost/hooks",
        "http://10.0.0.5/hooks",
        "http://192.168.1.1/hooks",
        "http://172.16.4.2/hooks",
        "http://[::1]/hooks",
        "http://metadata.google.internal/computeMetadata/v1/",
        "http://orders.internal/hooks",
        "ftp://example.com/hooks",
        "file:///etc/passwd",
        "not a url at all"
      ]

      for url <- refused do
        assert {:error, changeset} =
                 Settings.update_section(
                   Settings.get_organization(),
                   %{"webhook_url" => url},
                   :integrations
                 ),
               "#{url} was accepted as a webhook endpoint"

        assert changeset.errors[:webhook_url]
      end
    end

    test "accepts an ordinary public endpoint" do
      assert {:ok, organization} =
               Settings.update_section(
                 Settings.get_organization(),
                 %{"webhook_url" => "https://hooks.example.test/incoming"},
                 :integrations
               )

      assert organization.webhook_url == "https://hooks.example.test/incoming"
    end

    test "clearing it is still allowed" do
      assert {:ok, organization} =
               Settings.update_section(
                 Settings.get_organization(),
                 %{"webhook_url" => ""},
                 :integrations
               )

      assert organization.webhook_url in [nil, ""]
    end
  end
end
