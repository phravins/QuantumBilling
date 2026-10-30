defmodule QuantumBillingWeb.Plugs.CheckBusinessMigrationsTest do
  # Not async: it builds a schema, and DDL takes catalogue locks.
  use QuantumBillingWeb.ConnCase, async: false

  alias QuantumBilling.Release
  alias QuantumBilling.Repo
  alias QuantumBillingWeb.Plugs.CheckBusinessMigrations

  test "lets the request through when every schema is up to date", %{conn: conn} do
    refute CheckBusinessMigrations.call(conn, []).halted
  end

  test "names a schema that is behind, and what to run", %{conn: conn} do
    %{rows: [[version]]} = Repo.query!("SELECT max(version) FROM biz_1.schema_migrations")
    Repo.query!("DELETE FROM biz_1.schema_migrations WHERE version = $1", [version])

    assert [{"biz_1", [^version]}] = Release.pending_business_migrations(Repo)

    conn = CheckBusinessMigrations.call(conn, [])
    assert conn.halted
    assert conn.status == 503
    assert conn.resp_body =~ "biz_1"
    assert conn.resp_body =~ "mix ecto.migrate"
  end
end
