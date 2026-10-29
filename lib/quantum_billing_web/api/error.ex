defmodule QuantumBillingWeb.API.Error do
  @moduledoc """
  The one shape every API error takes:

      {"error": {"code": "not_found", "message": "…", "fields": {…}}}

  `code` is stable and meant for programs; `message` is for the person reading
  the log. Neither ever carries a stack trace, a query, a driver message or a
  value echoed back from the request — an error response is the easiest place
  for an API to say more than it meant to.
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
  Field errors from a changeset, as `%{"field" => ["message", …]}`.

  Messages only. `traverse_errors` interpolates the validation options into
  the message, never the submitted value, so nothing the caller sent is
  reflected back — which matters when what they sent was someone else's data.
  """
  def changeset_fields(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
