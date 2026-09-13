defmodule QuantumBillingWeb.RawBodyReader do
  @moduledoc """
  Keeps the exact bytes of a webhook request body so its signature can be
  checked.

  A signature covers the body as it was sent. Once `Plug.Parsers` has decoded
  the JSON, re-encoding the params gives a different document — different key
  order, different number formatting, different escaping — and its HMAC does
  not match. Verification against re-encoded params therefore fails for honest
  requests and, worse, invites the "if it doesn't match, skip the check"
  workaround.

  Only webhook paths are captured. Holding a copy of every uploaded file and
  every form submission in memory, for requests that will never be verified,
  is a memory cost with no purpose.
  """

  @capture_prefixes ["/api/webhooks"]

  # A webhook payload is a few kilobytes. Anything past this is not one, and
  # buffering it whole — which is what capturing means — would let a stranger
  # decide how much memory this process uses.
  @max_capture_bytes 1_000_000

  @doc """
  Reads the body, stashing it in `conn.private[:raw_body]` on webhook paths.

  Chunked reads are accumulated: `Plug.Conn.read_body/2` returns `:more` for a
  body larger than its read length, and keeping only the first chunk would
  produce a signature mismatch on exactly the large payloads that matter.
  """
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
        # Over the cap: hand the read back to the parser, which applies its own
        # limit. Nothing is stashed, so the request has no verifiable body and
        # the webhook handler rejects it — which is the right answer for
        # something this far outside the shape of a webhook.
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
