defmodule QuantumBillingWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use QuantumBillingWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
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

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav_items, nav_items())

    ~H"""
    <div class="flex min-h-screen bg-base-100">
      <aside class="sticky top-0 flex h-screen w-[230px] shrink-0 flex-col border-r border-base-300">
        <div class="flex items-center gap-2 px-5 py-5">
          <div class="flex size-8 items-center justify-center rounded-lg bg-primary text-primary-content">
            <.icon name="hero-receipt-percent" class="size-5" />
          </div>
          <span class="text-lg font-bold">GST Invoice</span>
        </div>

        <nav class="flex-1 overflow-y-auto px-3">
          <ul class="space-y-1">
            <li :for={item <- @nav_items}>
              <.link
                navigate={item.path}
                class={[
                  "flex items-center gap-3 rounded-field px-3 py-2 text-sm text-base-content/70 hover:bg-base-200",
                  @active_nav == item.key &&
                    "border-l-4 border-primary bg-primary/10 font-semibold text-primary hover:bg-primary/10"
                ]}
              >
                <.icon name={item.icon} class="size-5" />
                {item.label}
              </.link>
            </li>
          </ul>
        </nav>

        <div class="m-3 rounded-box bg-base-200 p-4 text-center">
          <.icon name="hero-question-mark-circle" class="mx-auto size-6 text-base-content/50" />
          <p class="mt-2 text-sm font-semibold">Need Help?</p>
          <p class="mt-1 text-xs text-base-content/60">Contact support for any assistance.</p>
          <.button class="btn btn-primary btn-sm mt-3 w-full">Contact Support</.button>
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="navbar border-b border-base-300 bg-base-100 px-6">
          <div class="flex-1">
            <button class="btn btn-ghost btn-circle" aria-label="Toggle sidebar">
              <.icon name="hero-bars-3" class="size-5" />
            </button>
          </div>
          <div class="flex flex-none items-center gap-4">
            <button class="btn btn-ghost btn-circle relative" aria-label="Notifications">
              <.icon name="hero-bell" class="size-5" />
              <span class="badge badge-error badge-xs absolute right-1 top-1">5</span>
            </button>

            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class="flex items-center gap-2 px-1">
                <div class="avatar avatar-placeholder">
                  <div class="w-9 rounded-full bg-primary text-primary-content">
                    <span class="text-xs">PS</span>
                  </div>
                </div>
                <div class="hidden text-left sm:block">
                  <p class="text-sm font-semibold leading-tight">Priya Sharma</p>
                  <p class="text-xs text-base-content/60">GST Officer</p>
                </div>
                <.icon name="hero-chevron-down" class="size-4 text-base-content/50" />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu z-10 mt-3 w-40 rounded-box bg-base-100 p-2 shadow"
              >
                <li><a>Profile</a></li>
                <li><a>Sign out</a></li>
              </ul>
            </div>
          </div>
        </header>

        <main class="flex-1 overflow-y-auto bg-base-200 px-6 py-6">
          {render_slot(@inner_block)}
        </main>

        <footer class="flex items-center justify-between border-t border-base-300 px-6 py-4 text-xs text-base-content/50">
          <span>© 2024 GST Invoice Software. All rights reserved.</span>
          <span>Version 1.0.0</span>
        </footer>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp nav_items do
    [
      %{key: :dashboard, label: "Dashboard", path: ~p"/dashboard", icon: "hero-squares-2x2"},
      %{key: :invoices, label: "Invoices", path: ~p"/invoices", icon: "hero-document-text"},
      %{key: :clients, label: "Clients", path: ~p"/clients", icon: "hero-users"},
      %{key: :e_way_bills, label: "E-Way Bills", path: ~p"/e-way-bills", icon: "hero-truck"},
      %{key: :reports, label: "Reports", path: ~p"/reports", icon: "hero-chart-bar"},
      %{
        key: :compliance,
        label: "Compliance",
        path: ~p"/compliance",
        icon: "hero-shield-check"
      },
      %{key: :settings, label: "Settings", path: ~p"/settings", icon: "hero-cog-6-tooth"}
    ]
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
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

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
