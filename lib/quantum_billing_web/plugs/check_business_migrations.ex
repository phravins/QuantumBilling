defmodule QuantumBillingWeb.Plugs.CheckBusinessMigrations do
  @moduledoc """
  Development only: stops the request when a business schema is behind on its
  migrations, and says which one and what to run.

  `Phoenix.Ecto.CheckRepoStatus` only knows the public migrations, and its "Run
  migrations" button only runs those. A schema left behind otherwise shows up as
  a 500 about a missing column on whichever page reads it first.
  """

  import Plug.Conn

  alias QuantumBilling.Release
  alias QuantumBilling.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    case Release.pending_business_migrations(Repo) do
      [] ->
        conn

      pending ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, message(pending))
        |> halt()
    end
  end

  defp message(pending) do
    schemas =
      Enum.map_join(pending, "\n", fn {schema, versions} ->
        "  #{schema}: #{Enum.join(versions, ", ")}"
      end)

    """
    Business schemas have migrations that have not been run:

    #{schemas}

    Back up the database, then run: mix ecto.migrate
    """
  end
end
