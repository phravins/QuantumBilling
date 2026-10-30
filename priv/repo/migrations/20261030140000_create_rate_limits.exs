defmodule QuantumBilling.Repo.Migrations.CreateRateLimits do
  @moduledoc """
  Rate-limit counters shared by every server; see
  `QuantumBilling.RateLimiter.Postgres`. In `public`: a limit on a sign-in
  address or an API key is not one business's.

  UNLOGGED: the counters are worth nothing after a crash and are rewritten
  constantly, so they skip the write-ahead log. A crash that empties the table
  only forgives whatever was being counted that minute.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE UNLOGGED TABLE public.rate_limits (
      key bytea PRIMARY KEY,
      count integer NOT NULL,
      reset_at timestamptz NOT NULL
    )
    """)

    create index(:rate_limits, [:reset_at], prefix: "public")
  end

  def down do
    drop table(:rate_limits, prefix: "public")
  end
end
