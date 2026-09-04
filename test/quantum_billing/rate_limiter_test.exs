defmodule QuantumBilling.RateLimiterTest do
  use ExUnit.Case, async: false

  alias QuantumBilling.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  test "allows attempts under the limit" do
    key = "test-key-allow"
    assert {:ok, 2} = RateLimiter.hit(key, 3, 60)
    assert {:ok, 1} = RateLimiter.hit(key, 3, 60)
    refute RateLimiter.limited?(key, 3)

    assert {:ok, 0} = RateLimiter.hit(key, 3, 60)
    assert RateLimiter.limited?(key, 3)
  end

  test "blocks attempts over the limit" do
    key = "test-key-block"
    assert {:ok, 1} = RateLimiter.hit(key, 2, 60)
    assert {:ok, 0} = RateLimiter.hit(key, 2, 60)
    assert {:error, :rate_limited, retry_after} = RateLimiter.hit(key, 2, 60)
    assert retry_after > 0
    assert RateLimiter.limited?(key, 2)
  end

  test "resets attempts on reset/1" do
    key = "test-key-reset"
    RateLimiter.hit(key, 2, 60)
    RateLimiter.hit(key, 2, 60)
    RateLimiter.hit(key, 2, 60)

    assert RateLimiter.limited?(key, 2)
    assert :ok = RateLimiter.reset(key)
    refute RateLimiter.limited?(key, 2)

    assert {:ok, 1} = RateLimiter.hit(key, 2, 60)
  end
end
