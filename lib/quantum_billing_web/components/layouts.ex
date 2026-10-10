defmodule QuantumBillingWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use QuantumBillingWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active_nav, :atom, default: nil, doc: "the key of the currently active sidebar item"

  attr :active_sub, :atom,
    default: nil,
    doc: "the key of the active settings section, when one is open"

  # Assigned by NotificationsHook; defaults cover pages rendered outside it.
  attr :notifications, :list, default: [], doc: "the newest notifications, newest first"

  attr :unread_count, :integer, default: 0, doc: "how many of them have not been read"

  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> assign(:nav_items, nav_items())
      |> assign(:settings_sections, visible_settings_sections(assigns[:current_scope]))

    ~H"""
    <div class="flex min-h-screen bg-base-200">
      <aside class="sticky top-0 flex h-screen w-48 shrink-0 flex-col border-r border-base-300 bg-base-100">
        <.brand_mark class="px-4 py-4" />
        <nav class="flex-1 overflow-y-auto px-2.5 pt-1">
          <p class={["px-3 pb-2", micro_label_class()]}>Menu</p>

          <ul class="space-y-0.5">
            <li :for={item <- @nav_items} class="group">
              <%!-- Opens off @active_sub so the list stays unfolded across settings sections; the 0fr to 1fr row track animates the height without JS. --%>
              <input
                :if={item.key == :settings}
                type="checkbox"
                id="settings-sections-toggle"
                phx-hook=".SettingsDisclosure"
                checked={@active_sub != nil}
                data-open={to_string(@active_sub != nil)}
                class="peer sr-only"
              />
              <div class="flex items-center gap-0.5">
                <.link
                  navigate={item.path}
                  class={[
                    "flex min-w-0 flex-1 items-center gap-2.5 rounded-field px-3 py-2",
                    "text-sm transition-colors",
                    if(@active_nav == item.key,
                      do: "bg-base-200 font-medium text-base-content",
                      else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
                    )
                  ]}
                >
                  <%!-- Each destination keeps its own hue, dimmed while inactive. --%>
                  <.icon
                    name={item.icon}
                    class={[
                      "size-4.5 shrink-0 transition-opacity",
                      item.color,
                      if(@active_nav == item.key,
                        do: "opacity-100",
                        else: "opacity-70 group-hover:opacity-100"
                      )
                    ]}
                  />
                  <span class="truncate">{item.label}</span>
                </.link>

                <label
                  :if={item.key == :settings}
                  for="settings-sections-toggle"
                  class={[
                    "flex size-7 shrink-0 cursor-pointer items-center justify-center rounded-field",
                    "text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
                  ]}
                >
                  <span class="sr-only">Show settings sections</span>
                  <.icon
                    name="hero-chevron-down"
                    class="size-4 transition-transform duration-200 group-has-[:checked]:rotate-180"
                  />
                </label>
              </div>

              <div
                :if={item.key == :settings}
                id="settings-sections"
                class={[
                  "grid grid-rows-[0fr] transition-[grid-template-rows] duration-200 ease-out",
                  "peer-checked:grid-rows-[1fr]"
                ]}
              >
                <ul class="ml-4 space-y-0.5 overflow-hidden border-l border-base-300 pl-3 pt-0.5">
                  <li :for={section <- @settings_sections}>
                    <.link
                      navigate={~p"/settings/#{section.key}"}
                      class={[
                        "block truncate rounded-field px-2.5 py-1.5 text-xs transition-colors",
                        if(@active_sub == section.key,
                          do: "bg-base-200 font-medium text-base-content",
                          else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
                        )
                      ]}
                    >
                      {section.short_title}
                    </.link>
                  </li>
                </ul>
              </div>
            </li>
          </ul>
        </nav>

        <div class="border-t border-base-300 p-2.5">
          <div class="dropdown dropdown-top w-full">
            <div
              tabindex="0"
              role="button"
              class="flex w-full items-center gap-2 rounded-field px-2 py-2 text-left hover:bg-base-200"
            >
              <span class={["shrink-0 bg-base-300 text-base-content", avatar_class()]}>
                {user_initials(@current_scope)}
              </span>

              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm font-medium leading-tight">
                  {user_name(@current_scope)}
                </span>

                <span
                  :if={user_designation(@current_scope)}
                  class="block truncate text-xs text-base-content/45"
                >
                  {user_designation(@current_scope)}
                </span>
              </span>
              <.icon name="hero-ellipsis-horizontal" class="size-4 shrink-0 text-base-content/45" />
            </div>

            <%!-- w-full: the sidebar is only 12rem wide. --%>
            <ul
              tabindex="0"
              class="dropdown-content menu z-10 mb-2 w-full rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
            >
              <li><.link navigate={~p"/users/profile"}>My profile</.link></li>
              <li><.link navigate={~p"/users/settings"}>Account settings</.link></li>

              <li>
                <.link href={~p"/users/log-out"} method="delete">Sign out</.link>
              </li>
            </ul>
          </div>
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="sticky top-0 z-10 flex h-12 items-center justify-end border-b border-base-300 bg-base-100 px-3">
          <%!-- Live feed from NotificationsHook; capped and scrollable. --%>
          <div class="dropdown dropdown-end">
            <div
              tabindex="0"
              role="button"
              id="notifications-bell"
              class="relative flex size-7 items-center justify-center rounded-field text-base-content/60 hover:bg-base-200 hover:text-base-content"
              aria-label={notifications_label(@unread_count)}
            >
              <.icon name="hero-bell" class="size-4.5" />
              <span
                :if={@unread_count > 0}
                class="absolute -right-0.5 -top-0.5 flex min-w-4 items-center justify-center rounded-full bg-rose-600 px-1 text-[0.625rem] font-semibold leading-4 text-white"
              >
                {if @unread_count > 9, do: "9+", else: @unread_count}
              </span>
            </div>

            <div
              tabindex="0"
              id="notifications-panel"
              class="dropdown-content z-20 mt-2 w-80 overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-lg sm:w-96"
            >
              <div class="flex items-center justify-between border-b border-base-300 px-4 py-2.5">
                <span class="text-sm font-semibold tracking-tight">Notifications</span>
                <button
                  :if={@unread_count > 0}
                  type="button"
                  id="notifications-mark-all"
                  phx-click="mark_all_notifications_read"
                  class="text-xs text-base-content/60 transition-colors hover:text-base-content"
                >
                  Mark all read
                </button>
              </div>

              <div :if={@notifications == []} class="px-4 py-8 text-center">
                <.icon name="hero-bell-slash" class="mx-auto size-5 text-base-content/30" />
                <p class="mt-2 text-sm text-base-content/60">Nothing new</p>
                <p class="mt-0.5 text-xs text-base-content/45">
                  Invoices, payments and filing reminders land here.
                </p>
              </div>

              <ul
                :if={@notifications != []}
                class="max-h-96 divide-y divide-base-300 overflow-y-auto"
              >
                <li :for={notification <- @notifications} id={"notification-#{notification.id}"}>
                  <%!-- A button, not a link: the server marks it read and then navigates, so the two cannot race. --%>
                  <button
                    type="button"
                    phx-click="open_notification"
                    phx-value-id={notification.id}
                    class={[
                      "flex w-full gap-3 px-4 py-3 text-left transition-colors hover:bg-base-200",
                      is_nil(notification.read_at) && "bg-base-200/40"
                    ]}
                  >
                    <span class={[
                      "mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full",
                      notification_tone(notification.severity)
                    ]}>
                      <.icon name={notification_icon(notification.kind)} class="size-3.5" />
                    </span>

                    <span class="min-w-0 flex-1">
                      <span class="flex items-baseline justify-between gap-2">
                        <span class={[
                          "truncate text-sm",
                          if(is_nil(notification.read_at),
                            do: "font-semibold",
                            else: "font-medium text-base-content/70"
                          )
                        ]}>
                          {notification.title}
                        </span>
                        <span class="shrink-0 text-xs text-base-content/45">
                          {relative_time(notification.inserted_at)}
                        </span>
                      </span>

                      <span :if={notification.body} class="mt-0.5 block text-xs text-base-content/60">
                        {notification.body}
                      </span>
                    </span>
                  </button>
                </li>
              </ul>
            </div>
          </div>
        </header>

        <%!-- A flex column so a page can give a panel flex-1 to fill the remaining height. --%>
        <main class="flex flex-1 flex-col overflow-y-auto px-2 pb-2 pt-2 sm:px-2.5 sm:pb-2.5">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    <.flash_group flash={@flash} />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SettingsDisclosure">
      // The server decides whether the list starts open: it is, exactly when a
      // settings section is on screen (data-open). This hook used to remember a
      // manual open in localStorage as well, which meant one click on the
      // chevron unfolded the list on every page from then on -- under Invoices,
      // under Clients, for ever. Nothing is remembered across pages now.
      const STALE_KEY = "qb:settings-sections-open"

      export default {
        mounted() {
          // Browsers that visited before the change still hold the old flag.
          try { localStorage.removeItem(STALE_KEY) } catch (_error) {}

          // `null` until the chevron is used on this page. Reset per mount:
          // arriving somewhere new is not an override.
          this.choice = null
          this.apply(this.el.dataset.open === "true")
          this.el.addEventListener("change", () => (this.choice = this.el.checked))
        },

        // LiveView puts a checkbox back to what the server rendered on every
        // diff -- a notification arriving is enough. A choice made on this page
        // has to survive that, so it is put back; otherwise the server's
        // answer stands.
        updated() {
          this.apply(this.choice === null ? this.el.dataset.open === "true" : this.choice)
        },

        // Not the user opening it, so it must not animate -- otherwise the
        // list would slide on every page load and every diff.
        apply(open) {
          if (this.el.checked === open) return

          const panel = document.getElementById("settings-sections")
          if (panel) panel.style.transition = "none"
          this.el.checked = open
          if (panel) requestAnimationFrame(() => (panel.style.transition = ""))
        }
      }
    </script>
    """
  end

  # Tolerates a nil scope. Hiding panels is a courtesy; the real check is on the server.
  defp visible_settings_sections(scope) do
    sections = QuantumBillingWeb.SettingsComponents.sections()

    if QuantumBilling.Accounts.Scope.owner?(scope) do
      sections ++
        [
          %{
            key: :team,
            title: "Team",
            short_title: "Team",
            subtitle: "Accounts and invitations",
            icon: "hero-user-group"
          }
        ]
    else
      Enum.reject(sections, &QuantumBillingWeb.SettingsLive.owner_only?(&1.key))
    end
  end

  defp user_name(%{user: %{full_name: name}}) when is_binary(name) and name != "", do: name
  defp user_name(%{user: %{email: email}}) when is_binary(email), do: email
  defp user_name(_scope), do: "Signed out"

  defp user_initials(%{user: %{full_name: name}}) when is_binary(name) and name != "" do
    case String.split(name, ~r/\s+/, trim: true) do
      [single] -> single |> String.slice(0, 2) |> String.upcase()
      [first, second | _] -> String.upcase(String.first(first) <> String.first(second))
    end
  end

  defp user_initials(%{user: %{email: email}}) when is_binary(email) do
    email |> String.slice(0, 2) |> String.upcase()
  end

  defp user_initials(_scope), do: "--"

  defp notifications_label(0), do: "Notifications, none unread"
  defp notifications_label(1), do: "Notifications, 1 unread"
  defp notifications_label(count), do: "Notifications, #{count} unread"

  # Kind picks the glyph, severity picks the colour.
  defp notification_icon("invoice"), do: "hero-document-text"
  defp notification_icon("payment"), do: "hero-banknotes"
  defp notification_icon("e_way_bill"), do: "hero-truck"
  defp notification_icon("compliance"), do: "hero-clipboard-document-check"
  defp notification_icon("mail"), do: "hero-envelope"
  defp notification_icon("client"), do: "hero-user-plus"
  defp notification_icon(_other), do: "hero-information-circle"

  defp notification_tone("success"), do: "bg-emerald-50 text-emerald-700"
  defp notification_tone("warning"), do: "bg-amber-50 text-amber-700"
  defp notification_tone("error"), do: "bg-rose-50 text-rose-700"
  defp notification_tone(_info), do: "bg-base-200 text-base-content/60"

  defp user_designation(%{user: %{designation: title}}) when is_binary(title) and title != "",
    do: title

  defp user_designation(_scope), do: nil

  # Literal class strings: Tailwind cannot see interpolated ones.
  defp nav_items do
    [
      %{
        key: :dashboard,
        label: "Dashboard",
        path: ~p"/dashboard",
        icon: "hero-squares-2x2",
        color: "text-blue-600 dark:text-blue-400"
      },
      %{
        key: :invoices,
        label: "Invoices",
        path: ~p"/invoices",
        icon: "hero-document-text",
        color: "text-indigo-600 dark:text-indigo-400"
      },
      %{
        key: :clients,
        label: "Clients",
        path: ~p"/clients",
        icon: "hero-users",
        color: "text-emerald-600 dark:text-emerald-400"
      },
      %{
        key: :e_way_bills,
        label: "E-Way Bills",
        path: ~p"/e-way-bills",
        icon: "hero-truck",
        color: "text-amber-600 dark:text-amber-400"
      },
      %{
        key: :hsn_finder,
        label: "HSN Finder",
        path: ~p"/hsn-finder",
        icon: "hero-magnifying-glass",
        color: "text-cyan-600 dark:text-cyan-400"
      },
      %{
        key: :reports,
        label: "Reports",
        path: ~p"/reports",
        icon: "hero-chart-bar",
        color: "text-violet-600 dark:text-violet-400"
      },
      %{
        key: :compliance,
        label: "Compliance",
        path: ~p"/compliance",
        icon: "hero-shield-check",
        color: "text-teal-600 dark:text-teal-400"
      },
      %{
        key: :recurring,
        label: "Recurring",
        path: ~p"/recurring",
        icon: "hero-arrow-path",
        color: "text-pink-600 dark:text-pink-400"
      },
      %{
        key: :bin,
        label: "Bin",
        path: ~p"/bin",
        icon: "hero-trash",
        color: "text-slate-600 dark:text-slate-400"
      },
      %{
        key: :settings,
        label: "Settings",
        path: ~p"/settings",
        icon: "hero-cog-6-tooth",
        color: "text-rose-600 dark:text-rose-400"
      }
    ]
  end

  @doc """
  Renders the shell used by the sign-in and sign-up pages: the form column
  centered in the viewport, with the branding and cross-link pinned to the
  top corners.

  ## Examples

      <Layouts.auth flash={@flash}>
        <:top_link><.link navigate={~p"/users/log-in"}>Login</.link></:top_link>
        <.form ...>
      </Layouts.auth>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  slot :top_link, doc: "the cross-link shown in the top-right corner"
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="relative flex min-h-screen flex-col items-center justify-center bg-base-100 px-4 py-20">
      <div class="absolute left-4 top-4 flex items-center gap-2 text-lg font-semibold tracking-tight text-base-content md:left-8 md:top-8">
        <.icon name="hero-receipt-percent" class="size-6" /> QuantumBilling
      </div>

      <div
        :if={@top_link != []}
        class="absolute right-4 top-4 text-sm font-medium text-base-content md:right-8 md:top-8"
      >
        {render_slot(@top_link)}
      </div>

      <div class="mx-auto flex w-full flex-col justify-center space-y-6 sm:w-[350px]">
        {render_slot(@inner_block)}
      </div>

      <p class="absolute inset-x-0 bottom-6 px-4 text-center text-xs text-base-content/60">
        GST invoicing, e-way bills and compliance — all in one place.
      </p>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the shell for public legal documents (terms, privacy). Reachable
  while signed out, so it deliberately avoids the app sidebar.

  ## Examples

      <Layouts.legal flash={@flash} title="Terms of Service" current_scope={@current_scope}>
        <.legal_section title="1. About these terms">...</.legal_section>
      </Layouts.legal>
  """
  attr :flash, :map, required: true
  attr :title, :string, required: true
  attr :current_scope, :map, default: nil
  attr :other_doc_path, :string, required: true
  attr :other_doc_label, :string, required: true

  slot :inner_block, required: true

  def legal(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col bg-base-100">
      <header class="border-b border-base-300">
        <div class="mx-auto flex max-w-3xl items-center justify-between px-6 py-5">
          <.link
            navigate={~p"/"}
            class="flex items-center gap-2 text-lg font-semibold text-base-content"
          >
            <.icon name="hero-receipt-percent" class="size-6" /> QuantumBilling
          </.link>

          <.link
            navigate={if @current_scope, do: ~p"/dashboard", else: ~p"/users/log-in"}
            class="text-sm font-medium text-base-content/60 hover:text-base-content"
          >
            {if @current_scope, do: "Back to dashboard", else: "Back to sign in"}
          </.link>
        </div>
      </header>

      <main class="mx-auto w-full max-w-3xl flex-1 px-6 py-12">
        <h1 class="text-3xl font-semibold tracking-tight text-base-content">{@title}</h1>

        <p class="mt-2 text-sm text-base-content/60">Draft — not yet in effect.</p>

        <div class="mt-8 rounded-field border border-amber-300 bg-amber-50 p-4">
          <p class="text-sm font-semibold text-amber-900">
            Template pending legal review — do not publish as-is.
          </p>

          <p class="mt-1 text-sm text-amber-800">
            This document is a starting structure, not legal advice. Have it reviewed by a
            qualified lawyer and fill in every
            <span class="rounded bg-amber-200 px-1 font-medium text-amber-900">highlighted</span>
            blank before making it public. Remove this notice once reviewed.
          </p>
        </div>

        <div class="mt-10 space-y-8">
          {render_slot(@inner_block)}
        </div>
      </main>

      <footer class="border-t border-base-300">
        <div class="mx-auto flex max-w-3xl flex-col gap-2 px-6 py-6 text-sm text-base-content/60 sm:flex-row sm:items-center sm:justify-between">
          <span>© {DateTime.utc_now().year} QuantumBilling. All rights reserved.</span>
          <.link
            navigate={@other_doc_path}
            class="underline underline-offset-4 hover:text-base-content"
          >
            {@other_doc_label}
          </.link>
        </div>
      </footer>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the centered title + subtitle block above an auth form.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, required: true

  def auth_heading(assigns) do
    ~H"""
    <div class="flex flex-col space-y-2 text-center">
      <h1 class="text-xl font-semibold tracking-tight text-base-content">{@title}</h1>

      <p class="text-sm text-base-content/60">{@subtitle}</p>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />
      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
