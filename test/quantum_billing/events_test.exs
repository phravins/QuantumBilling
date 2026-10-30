defmodule QuantumBilling.EventsTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Events

  describe "topics" do
    test "a business's data is shared within it, so its topics carry no user" do
      # Not keyed by user: everyone in the business sees the same list.
      QuantumBilling.Repo.with_business(%{id: 1, schema: "biz_1"}, fn ->
        assert Events.clients_topic() == "clients:biz_1"
        assert Events.invoices_topic() == "invoices:biz_1"
        assert Events.e_way_bills_topic() == "e_way_bills:biz_1"
        assert Events.settings_topic() == "settings:biz_1"
      end)
    end

    test "each business has its own topics" do
      one = QuantumBilling.Repo.with_business(%{id: 1, schema: "biz_1"}, &Events.invoices_topic/0)
      two = QuantumBilling.Repo.with_business(%{id: 2, schema: "biz_2"}, &Events.invoices_topic/0)

      refute one == two
    end

    test "with no business there is no business topic to use" do
      assert_raise QuantumBilling.Repo.NoBusinessError, &Events.invoices_topic/0
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
