defmodule QuantumBilling.Calendars.GoogleClient do
  @moduledoc """
  The Google Calendar API: the OAuth code flow and writing events.

  Asks for `calendar.events` only, so it can change events and nothing else in
  the account. No access token is stored; each sync gets a new one from the
  refresh token. Errors are plain atoms, because Google's responses and Req's
  exceptions can carry tokens and must not reach a log or a job's error list.
  """

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @revoke_url "https://oauth2.googleapis.com/revoke"
  @events_base "https://www.googleapis.com/calendar/v3/calendars"
  @scope "https://www.googleapis.com/auth/calendar.events"

  # Google refuses a reminder further ahead than four weeks.
  @max_reminder_minutes 40_320

  @doc "Whether this installation has an OAuth client to sign in with."
  def configured? do
    is_binary(client_id()) and client_id() != "" and
      is_binary(client_secret()) and client_secret() != ""
  end

  @doc "Where to send the owner to grant access."
  def authorize_url(state, redirect_uri) do
    query =
      URI.encode_query(%{
        "client_id" => client_id(),
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => @scope,
        "access_type" => "offline",
        "prompt" => "consent",
        "state" => state
      })

    @authorize_url <> "?" <> query
  end

  @doc "Trades the code from the callback for a refresh token."
  def exchange_code(code, redirect_uri) do
    form = [
      code: code,
      client_id: client_id(),
      client_secret: client_secret(),
      redirect_uri: redirect_uri,
      grant_type: "authorization_code"
    ]

    case post_form(@token_url, form) do
      {:ok, %{status: 200, body: %{"refresh_token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: 200}} ->
        {:error, :no_refresh_token}

      _other ->
        {:error, :unavailable}
    end
  end

  @doc "A short-lived access token. `:reauthorize` means the grant is gone."
  def access_token(refresh_token) do
    form = [
      refresh_token: refresh_token,
      client_id: client_id(),
      client_secret: client_secret(),
      grant_type: "refresh_token"
    ]

    case post_form(@token_url, form) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: status, body: %{"error" => "invalid_grant"}}} when status in 400..401 ->
        {:error, :reauthorize}

      _other ->
        {:error, :unavailable}
    end
  end

  @doc "Tells Google to forget the grant. Best effort: the row is deleted regardless."
  def revoke(token) do
    _ = post_form(@revoke_url, token: token)
    :ok
  end

  @doc """
  Creates or updates the event with this id.

  The id is ours, derived from the item, so a retry cannot add a second event.
  Google remembers a deleted id and answers 409, which is why that case updates
  and sets the event back to confirmed.
  """
  def put_event(token, calendar_id, event_id, item, exists?) do
    body = event_body(event_id, item)

    if exists? do
      case update(token, calendar_id, event_id, body) do
        {:error, :not_found} -> insert(token, calendar_id, event_id, body)
        result -> result
      end
    else
      insert(token, calendar_id, event_id, body)
    end
  end

  @doc "Deletes an event. One that is already gone counts as done."
  def delete_event(token, calendar_id, event_id) do
    case request(:delete, event_url(calendar_id, event_id), token, []) do
      {:ok, %{status: status}} when status in [200, 204, 404, 410] -> :ok
      other -> failure(other)
    end
  end

  defp insert(token, calendar_id, event_id, body) do
    url = @events_base <> "/" <> URI.encode_www_form(calendar_id) <> "/events"

    case request(:post, url, token, json: body) do
      {:ok, %{status: 409}} -> update(token, calendar_id, event_id, body)
      other -> saved(other, event_id)
    end
  end

  defp update(token, calendar_id, event_id, body) do
    token
    |> then(&request(:put, event_url(calendar_id, event_id), &1, json: body))
    |> saved(event_id)
  end

  defp saved({:ok, %{status: status, body: body}}, event_id) when status in 200..201 do
    etag = if is_map(body), do: body["etag"]
    {:ok, event_id, etag}
  end

  defp saved({:ok, %{status: 404}}, _event_id), do: {:error, :not_found}
  defp saved(other, _event_id), do: failure(other)

  defp failure({:ok, %{status: status}}) when status in [401, 403], do: {:error, :unauthorized}
  defp failure(_other), do: {:error, :unavailable}

  defp event_url(calendar_id, event_id) do
    @events_base <> "/" <> URI.encode_www_form(calendar_id) <> "/events/" <> event_id
  end

  defp event_body(event_id, item) do
    %{
      id: event_id,
      summary: item.title,
      description: item.description,
      status: "confirmed",
      transparency: "transparent",
      start: %{date: Date.to_iso8601(item.date)},
      end: %{date: Date.to_iso8601(Date.add(item.date, 1))},
      reminders: %{useDefault: false, overrides: overrides(item.alarm_days)}
    }
  end

  defp overrides(days) when is_integer(days) and days >= 0 do
    [%{method: "popup", minutes: min(days * 1440, @max_reminder_minutes)}]
  end

  defp overrides(_days), do: []

  defp post_form(url, form), do: send_request(method: :post, url: url, form: form)

  defp request(method, url, token, options) do
    send_request([method: method, url: url, auth: {:bearer, token}] ++ options)
  end

  defp send_request(options) do
    [receive_timeout: 10_000, retry: false, redirect: false]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:quantum_billing, :calendar_req_options, []))
    |> Req.request()
  end

  defp client_id, do: config(:client_id)
  defp client_secret, do: config(:client_secret)

  defp config(key) do
    :quantum_billing
    |> Application.get_env(:google_calendar, [])
    |> Keyword.get(key)
  end
end
