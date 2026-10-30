defmodule QuantumBillingWeb.CalendarFeedController do
  @moduledoc """
  The private calendar URL an owner gives to a calendar app.

  Calendar apps send no session and no cookies, so the token in the URL is the
  access control. Every failure is the same bare 404, so nothing can be learned
  about which businesses exist or which of them have a feed.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Calendars

  def show(conn, %{"slug" => slug, "token" => token}) do
    case Calendars.feed(slug, String.replace_suffix(token, ".ics", "")) do
      {:ok, ics} ->
        conn
        |> put_resp_content_type("text/calendar", "utf-8")
        |> put_resp_header("cache-control", "private, max-age=900")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("referrer-policy", "no-referrer")
        |> send_resp(200, ics)

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(404, "Not found")
    end
  end
end
