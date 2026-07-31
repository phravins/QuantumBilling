defmodule QuantumBilling.EventsTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Events

  describe "topics" do
    test "organisation data is shared, so its topics carry no user" do
      # Two signed-in users looking at /clients see the same list, so a write by
      # one has to reach the other. Keying these by user would silently break
      # that.
      assert Events.clients_topic() == "clients"
      assert Events.invoices_topic() == "invoices"
      assert Events.e_way_bills_topic() == "e_way_bills"
      assert Events.settings_topic() == "settings"
    end

    test "a user's own account is keyed by id" do
      assert Events.user_topic(7) == "user:7"
      refute Events.user_topic(7) == Events.user_topic(8)
    end
  end

  describe "subscribe/1 and broadcast/2" do
    test "a subscriber receives what is published" do
      Events.subscribe("test:topic")

      Events.broadcast("test:topic", {:something_happened, 42})

      assert_receive {:something_happened, 42}
    end

    test "broadcasting to nobody is still fine" do
      # A write must never fail because no page happened to be open.
      assert Events.broadcast("test:nobody-listening", {:ignored, 1}) == :ok
    end

    test "messages on other topics are not delivered" do
      Events.subscribe("test:mine")

      Events.broadcast("test:theirs", {:not_for_me, 1})

      refute_receive {:not_for_me, 1}, 50
    end

    test "unsubscribe/1 stops delivery" do
      Events.subscribe("test:leaving")
      Events.unsubscribe("test:leaving")

      Events.broadcast("test:leaving", {:too_late, 1})

      refute_receive {:too_late, 1}, 50
    end
  end

  describe "broadcast_from/2" do
    test "reaches other processes but not the caller" do
      Events.subscribe("test:echo")

      task =
        Task.async(fn ->
          Events.subscribe("test:echo")
          assert_receive {:from_elsewhere, 1}, 500
          :received
        end)

      # Give the task time to subscribe before publishing.
      Process.sleep(50)
      Events.broadcast_from("test:echo", {:from_elsewhere, 1})

      assert Task.await(task) == :received
      refute_receive {:from_elsewhere, 1}, 50
    end
  end
end
