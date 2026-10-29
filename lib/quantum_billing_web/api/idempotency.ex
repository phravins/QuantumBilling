defmodule QuantumBillingWeb.API.Idempotency do
  @moduledoc """
  Makes an API write safe to retry.

  Every POST must carry an `Idempotency-Key` header: any string the caller
  chooses, up to 255 characters, unique per intended write. A UUID is the usual
  choice. If the response is lost — a timeout, a dropped connection — the
  caller sends the identical request with the same key, and gets the original
  response back instead of a second invoice.

  The header is required rather than optional because the failure it prevents
  is not cosmetic: every invoice consumes the next number in a statutory
  series, and a duplicate cannot simply be deleted without leaving a gap that
  has to be explained.

  What happens to a key:

    * first use — the write runs; its response (success or validation error)
      is stored for 24 hours;
    * the same key and the same body — the stored response is returned, with
      `idempotent-replayed: true`;
    * the same key and a different body — 422, because replaying the earlier
      response would answer a different question;
    * the same key while the first request is still running — 409.

  A crash or a 5xx is not stored: that was not the request's fault, and the
  caller should be able to retry it.
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

  # The method, the path and the decoded body. Decoded rather than raw, so a
  # retry that re-serialises the same JSON with its keys in another order or
  # different whitespace is still recognised as the same request.
  defp request_hash(conn) do
    payload = :erlang.term_to_binary(conn.body_params, [:deterministic])
    :crypto.hash(:sha256, [conn.method, " ", conn.request_path, "\n", payload])
  end
end
