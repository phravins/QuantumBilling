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
    <div class="flex min-h-screen bg-base-200">
      <aside class="sticky top-0 flex h-screen w-60 shrink-0 flex-col border-r border-base-300 bg-base-100">
        <div class="flex items-center gap-2.5 px-5 py-5">
          <div class="flex size-7 items-center justify-center rounded-field bg-primary text-primary-content">
            <.icon name="hero-receipt-percent" class="size-4" />
          </div>
          <span class="text-sm font-semibold tracking-tight">QuantumBilling</span>
        </div>

        <nav class="flex-1 overflow-y-auto px-3 pt-2">
          <p class={["px-3 pb-2", micro_label_class()]}>Menu</p>
          <ul class="space-y-0.5">
            <li :for={item <- @nav_items}>
              <.link
                navigate={item.path}
                class={[
                  "flex items-center gap-2.5 rounded-field px-3 py-2 text-sm transition-colors",
                  if(@active_nav == item.key,
                    do: "bg-base-200 font-medium text-base-content",
                    else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
                  )
                ]}
              >
                <.icon name={item.icon} class="size-4.5" />
                {item.label}
              </.link>
            </li>
          </ul>
        </nav>

        <div class="border-t border-base-300 p-3">
          <div class="dropdown dropdown-top w-full">
            <div
              tabindex="0"
              role="button"
              class="flex w-full items-center gap-2.5 rounded-field px-2 py-2 text-left hover:bg-base-200"
            >
              <span class={["shrink-0 bg-base-300 text-base-content", avatar_class()]}>
                {user_initials(@current_scope)}
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm font-medium leading-tight">
                  {user_name(@current_scope)}
                </span>
                <span class="block text-xs text-base-content/45">GST Officer</span>
              </span>
              <.icon name="hero-ellipsis-horizontal" class="size-4 shrink-0 text-base-content/45" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu z-10 mb-2 w-52 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
            >
              <li><.link navigate={~p"/users/settings"}>Account settings</.link></li>
              <li>
                <.link href={~p"/users/log-out"} method="delete">Sign out</.link>
              </li>
            </ul>
          </div>
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="sticky top-0 z-10 flex h-12 items-center justify-between border-b border-base-300 bg-base-100 px-6">
          <button
            class="flex size-7 items-center justify-center rounded-field text-base-content/60 hover:bg-base-200 hover:text-base-content"
            aria-label="Toggle sidebar"
          >
            <.icon name="hero-bars-3" class="size-4.5" />
          </button>

          <button
            class="relative flex size-7 items-center justify-center rounded-field text-base-content/60 hover:bg-base-200 hover:text-base-content"
            aria-label="Notifications"
          >
            <.icon name="hero-bell" class="size-4.5" />
            <span class="absolute right-1 top-1 size-1.5 rounded-full bg-error"></span>
          </button>
        </header>

        <main class="flex-1 overflow-y-auto px-6 py-6 sm:px-8 sm:py-8">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # The topbar renders before anyone signs in (and in tests that mount the
  # layout without a scope), so both helpers tolerate a nil scope.
  defp user_name(%{user: %{email: email}}) when is_binary(email), do: email
  defp user_name(_scope), do: "Signed out"

  defp user_initials(%{user: %{email: email}}) when is_binary(email) do
    email |> String.slice(0, 2) |> String.upcase()
  end

  defp user_initials(_scope), do: "--"

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
    <div class="relative flex min-h-screen flex-col items-center justify-center bg-white px-4 py-20">
      <div class="absolute left-4 top-4 flex items-center gap-2 text-lg font-semibold tracking-tight text-zinc-950 md:left-8 md:top-8">
        <.icon name="hero-receipt-percent" class="size-6" /> QuantumBilling
      </div>

      <div
        :if={@top_link != []}
        class="absolute right-4 top-4 text-sm font-medium text-zinc-950 md:right-8 md:top-8"
      >
        {render_slot(@top_link)}
      </div>

      <div class="mx-auto flex w-full flex-col justify-center space-y-6 sm:w-[350px]">
        {render_slot(@inner_block)}
      </div>

      <p class="absolute inset-x-0 bottom-6 px-4 text-center text-xs text-zinc-500">
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
    <div class="flex min-h-screen flex-col bg-white">
      <header class="border-b border-zinc-200">
        <div class="mx-auto flex max-w-3xl items-center justify-between px-6 py-5">
          <.link
            navigate={~p"/"}
            class="flex items-center gap-2 text-lg font-semibold text-zinc-950"
          >
            <.icon name="hero-receipt-percent" class="size-6" /> QuantumBilling
          </.link>
          <.link
            navigate={if @current_scope, do: ~p"/dashboard", else: ~p"/users/log-in"}
            class="text-sm font-medium text-zinc-600 hover:text-zinc-950"
          >
            {if @current_scope, do: "Back to dashboard", else: "Back to sign in"}
          </.link>
        </div>
      </header>

      <main class="mx-auto w-full max-w-3xl flex-1 px-6 py-12">
        <h1 class="text-3xl font-semibold tracking-tight text-zinc-950">{@title}</h1>
        <p class="mt-2 text-sm text-zinc-500">Draft — not yet in effect.</p>

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

      <footer class="border-t border-zinc-200">
        <div class="mx-auto flex max-w-3xl flex-col gap-2 px-6 py-6 text-sm text-zinc-500 sm:flex-row sm:items-center sm:justify-between">
          <span>© {DateTime.utc_now().year} QuantumBilling. All rights reserved.</span>
          <.link navigate={@other_doc_path} class="underline underline-offset-4 hover:text-zinc-900">
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
      <h1 class="text-2xl font-semibold tracking-tight text-zinc-950">{@title}</h1>
      <p class="text-sm text-zinc-500">{@subtitle}</p>
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
