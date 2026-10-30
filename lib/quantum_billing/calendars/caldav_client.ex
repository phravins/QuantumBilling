defmodule QuantumBilling.Calendars.CaldavClient do
  @moduledoc """
  CalDAV: one `.ics` resource per event, under the calendar's collection URL.

  The URL is typed by an owner, so `UrlGuard` checks it before every request and
  redirects are refused, for the same reasons as webhooks. A URL that is not
  https is refused too, because the password goes with every request. Errors are
  plain atoms, so neither the password nor a server's reply can reach a log.
  """

  alias QuantumBilling.Webhooks.UrlGuard

  @propfind_body """
  <?xml version="1.0" encoding="utf-8"?>
  <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>
  """

  @doc "Checks that the address and login work, before they are saved."
  def verify(url, username, password) do
    request("PROPFIND", url, username, password,
      headers: [{"depth", "0"}, {"content-type", "application/xml; charset=utf-8"}],
      body: @propfind_body
    )
    |> case do
      {:ok, %{status: 207}} -> :ok
      other -> failure(other)
    end
  end

  @doc "Writes one event, replacing any earlier copy. Returns its URL and etag."
  def put_event(url, username, password, uid, ics) do
    event_url = event_url(url, uid)

    request(:put, event_url, username, password,
      headers: [{"content-type", "text/calendar; charset=utf-8"}],
      body: ics
    )
    |> case do
      {:ok, %{status: status} = response} when status in [200, 201, 204] ->
        {:ok, event_url, etag(response)}

      other ->
        failure(other)
    end
  end

  @doc "Deletes one event. One that is already gone counts as done."
  def delete_event(event_url, username, password) do
    case request(:delete, event_url, username, password, []) do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      other -> failure(other)
    end
  end

  defp event_url(url, uid) do
    String.trim_trailing(url, "/") <> "/" <> URI.encode_www_form(uid) <> ".ics"
  end

  defp etag(response) do
    case Req.Response.get_header(response, "etag") do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp failure({:error, :blocked} = error), do: error
  defp failure({:ok, %{status: status}}) when status in [401, 403], do: {:error, :unauthorized}
  defp failure(_other), do: {:error, :unavailable}

  defp request(method, url, username, password, options) do
    with :ok <- check(url) do
      [
        method: method,
        url: url,
        auth: {:basic, username <> ":" <> password},
        receive_timeout: 10_000,
        retry: false,
        redirect: false,
        decode_body: false
      ]
      |> Keyword.merge(options)
      |> Keyword.merge(Application.get_env(:quantum_billing, :calendar_req_options, []))
      |> Req.request()
    end
  end

  defp check("https://" <> _rest = url) do
    case UrlGuard.check(url) do
      :ok -> :ok
      {:error, _reason} -> {:error, :blocked}
    end
  end

  defp check(_url), do: {:error, :blocked}
end
