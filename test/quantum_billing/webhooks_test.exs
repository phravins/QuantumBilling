defmodule QuantumBilling.WebhooksTest do
  use QuantumBilling.DataCase, async: true

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
end
