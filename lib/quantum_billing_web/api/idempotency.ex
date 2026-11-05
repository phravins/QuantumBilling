defmodule QuantumBillingWeb.API.Idempotency do
  @moduledoc """
  Makes API writes safe to retry. Every POST needs an `Idempotency-Key` (1-255 chars).

    * first use: runs, and the response is stored for 24 hours
    * same key and body: the stored response, with `idempotent-replayed: true`
    * same key, different body: 422
    * same key while the first is running: 409

  Crashes and 5xx responses are not stored, so they can be retried.
  """

  import Plug.Conn

  alias QuantumBilling.ApiKeys
  alias QuantumBillingWeb.API.Error

  @max_length 255

  @doc """
  Runs `write` — a function returning `{status, body}` — at most once per
  idempotency key, and sends the response.
  """
  def run(%Plug.Conn{assigns: %{api_key: api_key}} = conn, write) when is_function(write, 0) do
    with {:ok, key} <- idempotency_key(conn) do
      case ApiKeys.begin_idempotent(api_key, key, request_hash(conn)) do
        {:proceed, record} ->
          perform(conn, record, write)

        {:replay, status, body} ->
          conn
          |> put_resp_header("idempotent-replayed", "true")
          |> put_resp_content_type("application/json")
          |> send_resp(status, body)

        {:error, :in_progress} ->
          Error.send(
            conn,
            409,
            :idempotency_in_progress,
            "A request with this Idempotency-Key is still being processed. Retry shortly."
          )

        {:error, :mismatch} ->
          Error.send(
            conn,
            422,
            :idempotency_mismatch,
            "This Idempotency-Key was already used for a different request. " <>
              "Use a new key for a new write."
          )
      end
    else
      {:error, message} -> Error.send(conn, 400, :idempotency_key_required, message)
    end
  end

  defp perform(conn, record, write) do
    {status, body} =
      try do
        write.()
      rescue
        exception ->
          ApiKeys.abandon_idempotent(record)
          reraise exception, __STACKTRACE__
      end

    encoded = Jason.encode!(body)

    if status < 500 do
      ApiKeys.complete_idempotent(record, status, encoded)
    else
      ApiKeys.abandon_idempotent(record)
    end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, encoded)
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] ->
        key = String.trim(key)

        if key != "" and byte_size(key) <= @max_length and String.printable?(key) do
          {:ok, key}
        else
          {:error, "The Idempotency-Key header must be 1 to #{@max_length} printable characters."}
        end

      _missing_or_repeated ->
        {:error, "Writes need an Idempotency-Key header, so that a retry cannot write twice."}
    end
  end

  # Compares the decoded body, so key order and whitespace don't matter.
  defp request_hash(conn) do
    payload = :erlang.term_to_binary(conn.body_params, [:deterministic])
    :crypto.hash(:sha256, [conn.method, " ", conn.request_path, "\n", payload])
  end
end
