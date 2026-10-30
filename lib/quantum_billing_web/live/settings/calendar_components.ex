defmodule QuantumBillingWeb.CalendarComponents do
  @moduledoc """
  The calendar cards on Settings › Integrations: Google, CalDAV and the private
  feed. Saved credentials are never rendered, and a feed URL appears only in the
  response that created it.
  """
  use QuantumBillingWeb, :html

  attr :connections, :map, required: true
  attr :google_configured, :boolean, required: true
  attr :caldav_form, Phoenix.HTML.Form, required: true
  attr :new_feed_url, :string, default: nil

  def calendar_cards(assigns) do
    ~H"""
    <section id="calendar-integrations" class="mb-4 rounded-xl border border-base-300 p-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h3 class="text-sm font-semibold tracking-tight">Compliance calendars</h3>
          <p class="mt-1 text-xs text-base-content/60">
            Open tasks and upcoming GST returns are sent to these calendars. Changes made in a
            calendar do not come back here.
          </p>
        </div>
        <button
          :if={@connections["google"] || @connections["caldav"]}
          type="button"
          id="calendar-sync"
          phx-click="sync_calendars"
          phx-disable-with="Starting..."
          class={secondary_button()}
        >
          <.icon name="hero-arrow-path" class="size-4" /> Sync now
        </button>
      </div>

      <div class="mt-4 grid gap-3 lg:grid-cols-3">
        <article id="calendar-google" class="flex flex-col rounded-lg border border-base-200 p-4">
          <.card_heading icon="hero-calendar-days" title="Google Calendar" />
          <p class="mt-2 text-xs text-base-content/60">
            Adds events to your primary calendar, with permission to change events only.
          </p>
          <.connection_status connection={@connections["google"]} />
          <div class="mt-auto pt-3">
            <%= cond do %>
              <% @connections["google"] -> %>
                <.disconnect_button provider="google" />
              <% @google_configured -> %>
                <.link
                  href={~p"/integrations/google/connect"}
                  id="google-connect"
                  class={primary_button()}
                >
                  Connect Google Calendar
                </.link>
              <% true -> %>
                <p id="google-not-configured" class="text-xs text-base-content/60">
                  Not configured. Set GOOGLE_CALENDAR_CLIENT_ID and GOOGLE_CALENDAR_CLIENT_SECRET
                  on the server.
                </p>
            <% end %>
          </div>
        </article>

        <article id="calendar-caldav" class="flex flex-col rounded-lg border border-base-200 p-4">
          <.card_heading icon="hero-server-stack" title="CalDAV" />
          <p class="mt-2 text-xs text-base-content/60">
            Nextcloud, iCloud, Fastmail and others. Use the calendar's own URL and an app password.
          </p>
          <.connection_status connection={@connections["caldav"]} />
          <%= if @connections["caldav"] do %>
            <p class="mt-2 break-all text-xs text-base-content/60">
              {@connections["caldav"].username} at {@connections["caldav"].url}
            </p>
            <div class="mt-auto pt-3"><.disconnect_button provider="caldav" /></div>
          <% else %>
            <.form for={@caldav_form} id="caldav-form" phx-submit="connect_caldav" class="mt-1">
              <.input
                field={@caldav_form[:url]}
                type="url"
                label="Calendar URL"
                placeholder="https://cloud.example.com/remote.php/dav/calendars/me/work/"
                autocomplete="off"
              />
              <.input
                field={@caldav_form[:username]}
                type="text"
                label="Username"
                autocomplete="off"
              />
              <.input
                field={@caldav_form[:password]}
                type="password"
                label="App password"
                value=""
                autocomplete="new-password"
              />
              <button
                type="submit"
                id="caldav-connect"
                phx-disable-with="Checking..."
                class={[primary_button(), "mt-2"]}
              >
                Connect CalDAV
              </button>
            </.form>
          <% end %>
        </article>

        <article id="calendar-feed" class="flex flex-col rounded-lg border border-base-200 p-4">
          <.card_heading icon="hero-link" title="Calendar link" />
          <p class="mt-2 text-xs text-base-content/60">
            A private URL for Outlook, Apple Calendar or anything else that can subscribe to one.
            Anyone holding it can read these deadlines.
          </p>
          <div
            :if={@new_feed_url}
            id="feed-url"
            class="mt-3 rounded-lg border border-amber-500/40 bg-amber-500/10 p-3"
          >
            <p class="text-xs font-medium">Copy this now. It will not be shown again.</p>
            <code class="mt-1 block select-all break-all text-xs">{@new_feed_url}</code>
          </div>
          <p
            :if={@connections["feed"] && !@new_feed_url}
            id="feed-active"
            class="mt-3 text-xs font-medium text-emerald-600"
          >
            Active
          </p>
          <div class="mt-auto flex flex-wrap gap-2 pt-3">
            <%= if @connections["feed"] do %>
              <button
                type="button"
                id="feed-regenerate"
                phx-click="regenerate_feed"
                data-confirm="Create a new link? The current one stops working straight away."
                class={secondary_button()}
              >
                New link
              </button>
              <.disconnect_button provider="feed" label="Turn off" />
            <% else %>
              <button
                type="button"
                id="feed-create"
                phx-click="regenerate_feed"
                class={primary_button()}
              >
                Create link
              </button>
            <% end %>
          </div>
        </article>
      </div>
    </section>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true

  defp card_heading(assigns) do
    ~H"""
    <h4 class="flex items-center gap-2 text-sm font-semibold">
      <.icon name={@icon} class="size-4 text-base-content/60" /> {@title}
    </h4>
    """
  end

  attr :connection, :any, required: true

  defp connection_status(%{connection: nil} = assigns), do: ~H""

  defp connection_status(assigns) do
    ~H"""
    <p
      :if={@connection.last_error}
      id={"calendar-error-#{@connection.provider}"}
      class="mt-3 text-xs font-medium text-rose-600"
    >
      {@connection.last_error}
    </p>
    <p
      :if={!@connection.last_error}
      id={"calendar-connected-#{@connection.provider}"}
      class="mt-3 text-xs font-medium text-emerald-600"
    >
      Connected{last_synced(@connection.last_synced_at)}
    </p>
    """
  end

  attr :provider, :string, required: true
  attr :label, :string, default: "Disconnect"

  defp disconnect_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"calendar-disconnect-#{@provider}"}
      phx-click="disconnect_calendar"
      phx-value-provider={@provider}
      data-confirm="Disconnect this calendar? Events already in it stay there."
      class={secondary_button()}
    >
      {@label}
    </button>
    """
  end

  defp last_synced(nil), do: ""
  defp last_synced(at), do: Calendar.strftime(at, " · last synced %d %b %Y, %H:%M UTC")

  defp primary_button do
    "inline-flex cursor-pointer items-center justify-center gap-1.5 rounded-lg bg-primary px-3 py-2 " <>
      "text-xs font-semibold text-primary-content transition hover:opacity-90 " <>
      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
  end

  defp secondary_button do
    "inline-flex cursor-pointer items-center justify-center gap-1.5 rounded-lg border " <>
      "border-base-300 px-3 py-2 text-xs font-semibold transition hover:bg-base-200 " <>
      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
  end
end
