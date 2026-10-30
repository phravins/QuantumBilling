defmodule QuantumBillingWeb.HealthController do
  @moduledoc """
  Liveness and readiness for load balancers and process supervisors.

  ## Why it checks the database

  A health endpoint that only proves the web server accepted a socket is worse
  than none: a node whose database connection has been exhausted or whose
  credentials are wrong answers it happily while every real request 500s. So
  this runs `SELECT 1` and reports unhealthy when that fails, which is what
  makes a load balancer's health check mean something.

  ## Why it is JSON on the `:api` pipeline

  It deliberately does not go through `:browser`: no session, no CSRF token, no
  `fetch_current_scope_for_user`. A probe that needs to load a session from the
  database tells you nothing at the moment the database is the problem.

  ## Why it says so little

  This answers anyone on the internet, signed in or not. It used to return the
  database driver's own error text on failure — and Postgrex messages carry
  exactly what an attacker wants: `password authentication failed for user
  "postgres"` names the account, connection errors name the host and the
  database. It also published the application version on every call, which is
  a lookup key for known vulnerabilities.

  An orchestrator needs one bit — healthy or not — and gets it from the status
  code. The detail goes to the log, where the people who can act on it are.
  """
  use QuantumBillingWeb, :controller

  require Logger

  alias QuantumBilling.Repo

  @doc """
  Returns 200 with `{"status": "ok"}` when the database answers, 503 otherwise.
  """
  def index(conn, _params) do
    {status, body} = payload(database_status())

    conn
    |> put_status(status)
    |> json(body)
  end

  @doc """
  The status and body for a database check result.

  Public so the failure body can be asserted on directly: making the real
  database fail inside a test suite that depends on it is not a reasonable way
  to prove this leaks nothing.
  """
  def payload(:ok), do: {200, %{status: "ok", database: "ok"}}

  def payload({:error, reason}) do
    # The detail is for operators, so it goes where they look. Nothing from
    # `reason` reaches the response.
    Logger.error("[Health] database check failed: #{reason}")

    {503, %{status: "error", database: "unavailable"}}
  end

  defp database_status do
    case Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  rescue
    # An exhausted pool raises rather than returning an error.
    error -> {:error, Exception.message(error)}
  catch
    :exit, _reason -> {:error, "database connection unavailable"}
  end
end
