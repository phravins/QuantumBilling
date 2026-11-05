defmodule Mix.Tasks.QuantumBilling.MigrateBusinesses do
  @shortdoc "Runs the tenant migrations in every business's schema"

  @moduledoc """
  Runs `priv/repo/tenant_migrations` in each business's schema.

      $ mix quantum_billing.migrate_businesses [--quiet]

  `mix ecto.migrate` already runs it; in a release, `Release.migrate/0` does both.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [quiet: :boolean])
    migrator_opts = if opts[:quiet], do: [log: false], else: []

    {:ok, _, _} =
      Ecto.Migrator.with_repo(QuantumBilling.Repo, fn repo ->
        QuantumBilling.Release.migrate_businesses(repo, migrator_opts)
      end)

    :ok
  end
end
