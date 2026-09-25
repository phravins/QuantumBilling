defmodule QuantumBillingWeb.HealthController do
  @moduledoc """
  Liveness and readiness for orchestrators.

  ## Why it checks the database

  A health endpoint that only proves the web server accepted a socket is worse
  than none: a container whose database connection has been exhausted or whose
  credentials are wrong answers it happily while every real request 500s. So
  this runs `SELECT 1` and reports unhealthy when that fails, which is what
  makes `docker compose`'s `service_healthy` condition mean something.

  ## Why it is JSON on the `:api` pipeline

  It deliberately does not go through `:browser`: no session, no CSRF token, no
  `fetch_current_scope_for_user`. A probe that needs to load a session from the
  database tells you nothing at the moment the database is the problem.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Repo

  @doc """
  Returns 200 with `{"status": "ok"}` when the database answers, 503 otherwise.
  """
  def index(conn, _params) do
    case database_status() do
      :ok ->
        json(conn, %{status: "ok", database: "ok", version: version()})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", database: reason, version: version()})
    end
  end

  defp database_status do
    case Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  rescue
    # A pool with no free connections raises rather than returning an error
    # tuple, and that is precisely the state a probe exists to catch.
    error -> {:error, Exception.message(error)}
  catch
    :exit, _reason -> {:error, "database connection unavailable"}
  end

  defp version do
    to_string(Application.spec(:quantum_billing, :vsn) || "unknown")
  end
end
