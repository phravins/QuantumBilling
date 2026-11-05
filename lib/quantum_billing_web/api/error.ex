defmodule QuantumBillingWeb.API.Error do
  @moduledoc """
  The single API error shape:

      {"error": {"code": "not_found", "message": "...", "fields": {...}}}

  `code` is stable for programs; `message` is for people. No traces, queries or echoed input.
  """

  import Plug.Conn

  @doc "Sends an error response and halts."
  def send(conn, status, code, message, fields \\ nil) do
    body =
      %{code: to_string(code), message: message}
      |> then(fn error -> if fields, do: Map.put(error, :fields, fields), else: error end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: body}))
    |> halt()
  end

  @doc """
  Changeset errors as `%{"field" => ["message", ...]}`. Never echoes submitted values.
  """
  def changeset_fields(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
