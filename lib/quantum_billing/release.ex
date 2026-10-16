defmodule QuantumBilling.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :quantum_billing

  @doc """
  Migrates `public`, then every business's schema.

  The order matters: a new public migration can be the one that creates a
  business table's home, and the businesses are read from `public`.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
          migrate_businesses(repo)
        end)
    end
  end

  @doc """
  Runs the tenant migrations in every business's schema, archived ones
  included: an archived business is still read, so its tables must match.
  """
  def migrate_businesses(repo, opts \\ []) do
    for schema <- business_schemas(repo) do
      Ecto.Migrator.run(
        repo,
        tenant_migrations_path(),
        :up,
        Keyword.merge([all: true, prefix: schema], opts)
      )
    end
  end

  @doc "Where the migrations that run in each business's schema live."
  def tenant_migrations_path do
    Application.app_dir(@app, "priv/repo/tenant_migrations")
  end

  defp business_schemas(repo) do
    import Ecto.Query, only: [from: 2]

    repo.all(from(b in "businesses", select: b.schema, order_by: b.id), prefix: "public")
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          priv_dir = :code.priv_dir(@app)
          seeds_file = Path.join(priv_dir, "repo/seeds.exs")
          if File.exists?(seeds_file), do: Code.eval_file(seeds_file)
        end)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
