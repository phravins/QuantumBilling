defmodule QuantumBillingWeb.HealthController do
  @moduledoc """
  Liveness and readiness for load balancers.

  Runs `SELECT 1`, on the `:api` pipeline so no session is needed. The response
  is only healthy or not; error details go to the log, never to the caller.
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

  @doc "The status and body for a database check result. Public for tests."
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
