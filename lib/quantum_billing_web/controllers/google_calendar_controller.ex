defmodule QuantumBillingWeb.GoogleCalendarController do
  @moduledoc """
  Connects a business to Google Calendar through the OAuth code flow.

  `state` is random, held in the session and used once. It stops someone tricking
  an owner into connecting the attacker's calendar, and it records which business
  the owner started from, so switching business in another tab midway connects
  nothing.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Calendars
  alias QuantumBilling.Calendars.GoogleClient

  @session_key :google_calendar_oauth
  @settings "/settings/integrations"

  def connect(conn, _params) do
    if GoogleClient.configured?() do
      state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      business = conn.assigns.current_scope.business

      conn
      |> put_session(@session_key, %{"state" => state, "business_id" => business.id})
      |> redirect(external: GoogleClient.authorize_url(state, redirect_uri()))
    else
      conn
      |> put_flash(:error, "Google Calendar is not configured on this server.")
      |> redirect(to: @settings)
    end
  end

  def callback(conn, params) do
    pending = get_session(conn, @session_key)
    conn = delete_session(conn, @session_key)

    cond do
      not valid_state?(pending, params["state"], conn.assigns.current_scope.business) ->
        failed(conn, "That Google sign-in could not be verified. Try connecting again.")

      is_binary(params["code"]) ->
        exchange(conn, params["code"])

      true ->
        failed(conn, "Google Calendar was not connected.")
    end
  end

  defp valid_state?(%{"state" => expected, "business_id" => id}, state, %{id: id})
       when is_binary(state) do
    Plug.Crypto.secure_compare(expected, state)
  end

  defp valid_state?(_pending, _state, _business), do: false

  defp exchange(conn, code) do
    case Calendars.connect_google(conn.assigns.current_scope, code, redirect_uri()) do
      {:ok, _connection} ->
        conn
        |> put_flash(:info, "Google Calendar connected. Your deadlines are on their way.")
        |> redirect(to: @settings)

      {:error, _reason} ->
        failed(conn, "Google did not complete the connection. Try again.")
    end
  end

  defp failed(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: @settings)
  end

  defp redirect_uri, do: url(~p"/integrations/google/callback")
end
