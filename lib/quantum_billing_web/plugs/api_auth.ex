defmodule QuantumBillingWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates an API call by its bearer key (`Authorization: Bearer qb_live_...`).

  A key in the query string is refused, since URLs leak into logs. Every other
  failure gets the same 401, so a guess reveals nothing. The key's business is
  made current (`Repo.put_business/1`); nothing in the request can choose another.
  """

  import Plug.Conn

  alias QuantumBilling.ApiKeys
  alias QuantumBilling.Repo
  alias QuantumBillingWeb.API.Error
  alias QuantumBillingWeb.ClientIP

  @query_names ~w(api_key apikey key token access_token)

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    cond do
      Enum.any?(@query_names, &Map.has_key?(conn.query_params, &1)) ->
        Error.send(
          conn,
          400,
          :key_in_url,
          "Send the API key in the Authorization header, never in the URL. A key that " <>
            "has appeared in a URL is in logs and history by now: revoke it and issue a new one."
        )

      true ->
        authenticate(conn)
    end
  end

  defp authenticate(conn) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         {:ok, key} <- ApiKeys.authenticate(String.trim(raw)) do
      ip = conn |> ClientIP.client_ip_tuple() |> ClientIP.to_string_ip()
      ApiKeys.touch(key, ip)
      Repo.put_business(key.business)

      conn
      |> assign(:api_key, key)
      |> assign(:api_client_ip, ip)
    else
      _missing_or_unusable ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="QuantumBilling API"))
        |> Error.send(401, :unauthorized, "A valid API key is required.")
    end
  end
end
