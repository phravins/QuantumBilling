defmodule QuantumBilling.RateLimiter.PostgresTest do
  @moduledoc """
  The shared backend, called directly: the suite as a whole runs on the ETS
  one (see config/test.exs).
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.RateLimiter.Postgres

  test "counts down to the limit, then refuses with a retry-after" do
    key = {:login, "203.0.113.5"}

    assert {:ok, 2} = Postgres.hit(key, 3, 60)
    assert {:ok, 1} = Postgres.hit(key, 3, 60)
    refute Postgres.limited?(key, 3)
    assert {:ok, 0} = Postgres.hit(key, 3, 60)
    assert Postgres.limited?(key, 3)

    assert {:error, :rate_limited, retry_after} = Postgres.hit(key, 3, 60)
    assert retry_after in 1..60
  end

  test "keys are counted separately" do
    assert {:ok, 0} = Postgres.hit({:api, 1, :write}, 1, 60)
    assert {:ok, 0} = Postgres.hit({:api, 2, :write}, 1, 60)
    assert {:error, :rate_limited, _} = Postgres.hit({:api, 1, :write}, 1, 60)
  end

  test "an ended window starts again" do
    key = "window-key"
    assert {:ok, 0} = Postgres.hit(key, 1, 60)
    assert {:error, :rate_limited, _} = Postgres.hit(key, 1, 60)

    Repo.query!("UPDATE public.rate_limits SET reset_at = now() - interval '1 second'", [])

    assert {:ok, 0} = Postgres.hit(key, 1, 60)
  end

  test "reset forgets a key" do
    key = "reset-key"
    Postgres.hit(key, 1, 60)
    assert Postgres.limited?(key, 1)

    Postgres.reset(key)

    refute Postgres.limited?(key, 1)
  end

  test "stores a hash of the key, never the address or email in it" do
    Postgres.hit({:login_email, "someone@example.com", "198.51.100.7"}, 5, 60)

    %{rows: rows} = Repo.query!("SELECT key::text FROM public.rate_limits", [])
    stored = inspect(rows)

    refute stored =~ "someone"
    refute stored =~ "198.51.100.7"
    assert [[hex]] = rows
    # bytea as text is \x followed by 64 hex digits: a SHA-256.
    assert byte_size(hex) == 2 + 64
  end

  test "parallel hits are each counted" do
    key = "parallel-key"

    results =
      1..20
      |> Task.async_stream(fn _ -> Postgres.hit(key, 10, 60) end, max_concurrency: 20)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 10
    assert Enum.count(results, &match?({:error, :rate_limited, _}, &1)) == 10
  end

  test "the sweep deletes only expired rows" do
    Postgres.hit("expired", 5, 60)
    Postgres.hit("current", 5, 60)

    Repo.query!(
      "UPDATE public.rate_limits SET reset_at = now() - interval '1 second' WHERE key = $1",
      [:crypto.hash(:sha256, :erlang.term_to_binary("expired", [:deterministic]))]
    )

    assert Postgres.sweep() == 1
    assert Postgres.limited?("current", 1)
  end

  test "runs under supervision and sweeps on its timer" do
    Postgres.hit("timer-expired", 5, 60)
    Repo.query!("UPDATE public.rate_limits SET reset_at = now() - interval '1 second'", [])

    pid = start_supervised!(Postgres)
    send(pid, :sweep)
    _ = :sys.get_state(pid)

    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM public.rate_limits", [])
    assert count == 0
  end

  test "production uses this backend unless configured otherwise" do
    previous = Application.get_env(:quantum_billing, :rate_limiter)
    Application.delete_env(:quantum_billing, :rate_limiter)
    on_exit(fn -> Application.put_env(:quantum_billing, :rate_limiter, previous) end)

    assert QuantumBilling.RateLimiter.backend() == Postgres
  end
end
