defmodule QuantumBillingWeb.RawBodyReader do
  @moduledoc """
  Keeps the raw body of webhook requests so signatures can be checked
  (re-encoded params would not match). Other paths are not captured.
  """

  @capture_prefixes ["/api/webhooks"]

  # Caps memory spent buffering; webhooks are a few kilobytes.
  @max_capture_bytes 1_000_000

  @doc "Reads the body, keeping all chunks in `conn.private[:raw_body]` on webhook paths."
  def read_body(conn, opts) do
    if capture?(conn) do
      read_and_capture(conn, opts, [], 0)
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  defp read_and_capture(conn, opts, chunks, size) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        body = IO.iodata_to_binary(Enum.reverse([chunk | chunks]))
        {:ok, body, Plug.Conn.put_private(conn, :raw_body, body)}

      {:more, chunk, conn} when size + byte_size(chunk) > @max_capture_bytes ->
        # Over the cap: nothing is stashed, so the webhook is rejected.
        {:more, chunk, conn}

      {:more, chunk, conn} ->
        read_and_capture(conn, opts, [chunk | chunks], size + byte_size(chunk))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture?(%Plug.Conn{request_path: path}) do
    Enum.any?(@capture_prefixes, &String.starts_with?(path, &1))
  end
end
