defmodule QuantumBillingWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates an API call by its bearer key.

  The key goes in `Authorization: Bearer qb_live_…` and nowhere else. A key in
  the query string is refused outright, with a message saying why: URLs are
  written to access logs, kept by proxies, stored in browser history and sent
  onward in `Referer` headers, so a key that has been in one should be thought
  of as published.

  Every other failure — no key, a malformed one, an unknown one, a revoked or
  expired one — gets the same 401 with the same body. Distinguishing them would
  tell whoever is guessing which of their guesses came close.

  ## The business

  A key belongs to one business, and authenticating it is what makes that
  business current for the request (`QuantumBilling.Repo.put_business/1`): every
  query after this point reads that business's schema and no other. Nothing in
  the request — no header, no parameter — can choose a different one.

  The endpoint clears any business a previous request on the same connection
  left behind (`forget_business` in `QuantumBillingWeb.Endpoint`), so a request
  refused here runs with no business at all, and any query it tried would raise.
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
