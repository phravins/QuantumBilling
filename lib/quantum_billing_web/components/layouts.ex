defmodule QuantumBillingWeb.Layouts do
  @moduledoc """
  Page shells: the app layout with the sidebar, and the focus, auth and legal layouts.
  """
  use QuantumBillingWeb, :html

  alias QuantumBilling.Accounts.Scope
  alias QuantumBillingWeb.SettingsComponents
  alias QuantumBillingWeb.SettingsLive

  embed_templates "layouts/*"

  @doc """
  Renders the app layout: sidebar, top bar and page content.

      <Layouts.app flash={@flash} current_scope={@current_scope}>
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

  attr :sidebar, :atom,
    default: :app,
    values: [:app, :settings],
    doc: "`:settings` swaps the main menu for the settings menu with a Back link"

  attr :layout_draft, :list,
    default: nil,
    doc: "the super admin's unsaved sidebar layout; shows the layout editor and its banner"

  # Assigned by NotificationsHook; defaults cover pages rendered outside it.
  attr :notifications, :list, default: [], doc: "the newest notifications, newest first"

  attr :unread_count, :integer, default: 0, doc: "how many of them have not been read"

  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> assign(:nav_items, nav_items(assigns[:current_scope]))

    ~H"""
    <.skip_link />
    <div class="flex min-h-screen bg-base-200">
      <%!-- Behind the drawer on narrow screens; a click outside closes it. --%>
      <div
        id="sidebar-backdrop"
        aria-hidden="true"
        phx-click={JS.dispatch("qb:close-drawer")}
        class="fixed inset-0 z-30 hidden bg-base-content/30 backdrop-blur-[1px] drawer-open:block lg:drawer-open:hidden"
      />

      <%!-- Wide: a column that collapses to an icon rail (data-sidebar on html). Narrow: a drawer (data-drawer). --%>
      <aside
        id="app-sidebar"
        class={[
          "fixed inset-y-0 left-0 z-40 h-dvh w-56 shrink-0 -translate-x-full overflow-hidden",
          "border-r border-base-300 bg-base-100 shadow-xl drawer-open:translate-x-0",
          "transition-[width,translate,border-color] duration-200 ease-out motion-reduce:transition-none",
          "lg:sticky lg:top-0 lg:h-screen lg:translate-x-0 lg:shadow-none",
          "lg:sidebar-collapsed:w-14 lg:sidebar-collapsed:overflow-visible"
        ]}
      >
        <div class="flex h-full w-56 flex-col lg:sidebar-collapsed:w-14">
          <div class="flex items-center justify-between gap-2 py-3 pl-4 pr-2.5 lg:sidebar-collapsed:justify-center lg:sidebar-collapsed:px-0">
            <.brand_mark class="lg:sidebar-collapsed:hidden" />
            <%!-- Rail top: the brand icon turns into an open button on hover. --%>
            <button
              type="button"
              id="sidebar-rail-expand"
              phx-click={JS.dispatch("qb:toggle-sidebar")}
              aria-label="Open sidebar"
              title="Open sidebar"
              aria-controls="app-sidebar"
              class="group/rail hidden size-8 items-center justify-center rounded-field text-base-content hover:bg-base-200 lg:sidebar-collapsed:flex"
            >
              <.icon name="hero-receipt-percent" class="size-5 group-hover/rail:hidden" />
              <.icon
                name="hero-chevron-double-right"
                class="hidden size-4 text-base-content/60 group-hover/rail:block"
              />
            </button>
            <button
              type="button"
              id="sidebar-collapse"
              phx-click={JS.dispatch("qb:toggle-sidebar")}
              aria-label="Close sidebar"
              title="Close sidebar"
              aria-controls="app-sidebar"
              class="flex size-7 shrink-0 items-center justify-center rounded-field text-base-content/45 hover:bg-base-200 hover:text-base-content lg:sidebar-collapsed:hidden"
            >
              <.icon name="hero-chevron-double-left" class="size-4" />
            </button>
          </div>
          <nav
            id={if(@sidebar == :settings, do: "settings-nav", else: "main-nav")}
            aria-label={if(@sidebar == :settings, do: "Settings", else: "Main")}
            class="flex-1 overflow-y-auto px-2.5 pt-1 lg:sidebar-collapsed:px-2"
          >
            <%= cond do %>
              <% @layout_draft -> %>
                <.layout_editor items={@layout_draft} />
              <% @sidebar == :settings -> %>
                <.settings_nav scope={@current_scope} active={@active_sub} />
              <% true -> %>
                <p class={["px-3 pb-2 lg:sidebar-collapsed:hidden", micro_label_class()]}>Menu</p>
                <ul class="space-y-0.5">
                  <li :for={item <- @nav_items} class="group">
                    <.nav_link
                      id={"nav-#{item.key}"}
                      path={item.path}
                      label={item.label}
                      icon={item.icon}
                      icon_class={item.color}
                      active={@active_nav == item.key}
                    />
                  </li>
                </ul>
            <% end %>
          </nav>

          <div class="border-t border-base-300 p-2.5 lg:sidebar-collapsed:p-2">
            <.action_menu
              id="sidebar-account-menu"
              label={"Account options for #{user_name(@current_scope)}"}
              class="w-full"
              trigger_class="flex w-full items-center gap-2 rounded-field px-2 py-2 text-left hover:bg-base-200 lg:sidebar-collapsed:justify-center lg:sidebar-collapsed:px-0"
              menu_class="z-10 bottom-full left-0 mb-2 w-full lg:sidebar-collapsed:w-48"
            >
              <:trigger>
                <span class={["shrink-0 bg-base-300 text-base-content", avatar_class()]}>
                  {user_initials(@current_scope)}
                </span>
                <span class="min-w-0 flex-1 lg:sidebar-collapsed:hidden">
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
                <.icon
                  name="hero-ellipsis-horizontal"
                  class="size-4 shrink-0 text-base-content/45 lg:sidebar-collapsed:hidden"
                />
              </:trigger>
              <li>
                <.link role="menuitem" navigate={~p"/users/profile"}>My profile</.link>
              </li>
              <li>
                <.link role="menuitem" navigate={~p"/users/settings"}>Account settings</.link>
              </li>
              <li>
                <.link role="menuitem" href={~p"/users/log-out"} method="delete">Sign out</.link>
              </li>
            </.action_menu>
          </div>
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <div
          :if={@layout_draft}
          id="layout-banner"
          role="region"
          aria-label="Layout customization"
          class="sticky top-0 z-20 flex flex-wrap items-center justify-between gap-3 bg-primary px-4 py-2 text-primary-content"
        >
          <p class="flex items-center gap-2 text-sm">
            <.icon name="hero-squares-plus" class="size-4" />
            <span class="font-medium">Layout customization</span>
            <span class="hidden opacity-70 sm:inline">· changes apply to everyone</span>
          </p>
          <div class="flex items-center gap-2">
            <button
              type="button"
              id="layout-cancel"
              phx-click="layout_cancel"
              class="rounded-field px-3 py-1 text-sm transition-colors hover:bg-primary-content/15"
            >
              Cancel
            </button>
            <button
              type="button"
              id="layout-save"
              phx-click="layout_save"
              class="rounded-field bg-primary-content px-3 py-1 text-sm font-medium text-primary transition-opacity hover:opacity-90"
            >
              Save
            </button>
          </div>
        </div>
        <header class="sticky top-0 z-10 flex h-12 items-center justify-between gap-3 border-b border-base-300 bg-base-100 px-3">
          <div class="flex min-w-0 items-center gap-1.5">
            <%!-- Narrow screens only: opens the drawer. --%>
            <button
              type="button"
              id="sidebar-expand"
              phx-click={JS.dispatch("qb:toggle-sidebar")}
              aria-label="Open sidebar"
              title="Open sidebar"
              aria-controls="app-sidebar"
              class="flex size-7 shrink-0 items-center justify-center rounded-field text-base-content/60 hover:bg-base-200 hover:text-base-content lg:hidden"
            >
              <.icon name="hero-bars-3" class="size-4.5" />
            </button>
            <.business_switcher scope={@current_scope} />
          </div>

          <%!-- Live feed from NotificationsHook. Absent outside a business. --%>
          <div :if={business_chosen?(@current_scope)} class="dropdown dropdown-end">
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
                  <%!-- A button: the server marks it read, then navigates. --%>
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

        <main
          id="main-content"
          tabindex="-1"
          class="flex flex-1 flex-col overflow-y-auto px-2 pb-2 pt-2 focus:outline-none sm:px-2.5 sm:pb-2.5"
        >
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  attr :scope, :any, required: true

  # Switching posts to a controller: only an HTTP response can write the session.
  defp business_switcher(assigns) do
    ~H"""
    <div :if={@scope && @scope.user} class="dropdown">
      <div
        tabindex="0"
        role="button"
        id="business-switcher"
        class={[
          "flex max-w-64 items-center gap-2 rounded-field px-2 py-1 text-sm",
          "transition-colors hover:bg-base-200"
        ]}
      >
        <span class="flex size-6 shrink-0 items-center justify-center rounded-md bg-base-200 text-base-content/60">
          <.icon name="hero-building-office-2" class="size-3.5" />
        </span>
        <span class="truncate font-medium">
          {if @scope.business, do: @scope.business.name, else: "Choose a business"}
        </span>
        <.icon name="hero-chevron-up-down" class="size-4 shrink-0 text-base-content/45" />
      </div>

      <div
        tabindex="0"
        id="business-switcher-menu"
        class="dropdown-content z-20 mt-2 w-72 overflow-hidden rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
      >
        <p class={["px-2.5 pb-1.5 pt-1", micro_label_class()]}>Businesses</p>
        <ul class="max-h-80 space-y-0.5 overflow-y-auto">
          <li :for={business <- @scope.businesses}>
            <.link
              href={~p"/businesses/#{business.id}/switch"}
              method="post"
              id={"switch-business-#{business.id}"}
              class={[
                "flex items-center gap-2 rounded-field px-2.5 py-2 text-sm transition-colors",
                if(current_business?(@scope, business),
                  do: "bg-base-200 font-medium",
                  else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
                )
              ]}
            >
              <span class="min-w-0 flex-1 truncate">{business.name}</span>
              <.icon
                :if={current_business?(@scope, business)}
                name="hero-check"
                class="size-4 shrink-0 text-primary"
              />
            </.link>
          </li>
        </ul>

        <div class="mt-1.5 space-y-0.5 border-t border-base-300 pt-1.5">
          <.link
            navigate={~p"/businesses"}
            class="flex items-center gap-2 rounded-field px-2.5 py-2 text-sm text-base-content/70 transition-colors hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-squares-2x2" class="size-4" /> All businesses
          </.link>
          <.link
            :if={Scope.owner?(@scope)}
            navigate={~p"/businesses/new"}
            id="new-business-link"
            class="flex items-center gap-2 rounded-field px-2.5 py-2 text-sm text-base-content/70 transition-colors hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-plus" class="size-4" /> New business
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp business_chosen?(%{business: %{}}), do: true
  defp business_chosen?(_scope), do: false

  defp current_business?(%{business: %{id: id}}, %{id: id}), do: true
  defp current_business?(_scope, _business), do: false

  attr :id, :string, required: true
  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :icon_class, :string, default: "text-base-content/70"
  attr :active, :boolean, default: false
  attr :method, :string, default: nil
  attr :external, :boolean, default: false

  # One sidebar row. Collapses to its icon on the rail, with the label kept for screen readers.
  defp nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={if(!@external and is_nil(@method), do: @path)}
      href={if(@external or @method != nil, do: @path)}
      method={@method || "get"}
      target={if(@external, do: "_blank")}
      rel={if(@external, do: "noopener noreferrer")}
      title={@label}
      aria-current={if(@active, do: "page")}
      class={[
        "group/nav flex min-w-0 items-center gap-2.5 rounded-field px-3 py-2",
        "text-sm transition-colors lg:sidebar-collapsed:justify-center lg:sidebar-collapsed:px-0",
        if(@active,
          do: "bg-base-200 font-medium text-base-content",
          else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
        )
      ]}
    >
      <.icon
        name={@icon}
        class={[
          "size-4.5 shrink-0 transition-opacity",
          @icon_class,
          if(@active, do: "opacity-100", else: "opacity-70 group-hover/nav:opacity-100")
        ]}
      />
      <span class="truncate lg:sidebar-collapsed:sr-only">{@label}</span>
      <.icon
        :if={@external}
        name="hero-arrow-up-right"
        class="ml-auto size-3 shrink-0 opacity-50 lg:sidebar-collapsed:hidden"
      />
    </.link>
    """
  end

  attr :scope, :any, required: true
  attr :active, :atom, default: nil

  defp settings_nav(assigns) do
    assigns = assign(assigns, :groups, settings_groups(assigns.scope))

    ~H"""
    <.link
      id="settings-back"
      navigate={if(business_chosen?(@scope), do: ~p"/dashboard", else: ~p"/businesses")}
      title="Back"
      class={[
        "group/back mb-2 flex items-center gap-1.5 rounded-field px-3 py-2 text-sm font-medium",
        "text-base-content/70 transition-colors hover:bg-base-200 hover:text-base-content",
        "lg:sidebar-collapsed:justify-center lg:sidebar-collapsed:px-0"
      ]}
    >
      <.icon
        name="hero-chevron-left"
        class="size-4 shrink-0 transition-transform group-hover/back:-translate-x-0.5"
      />
      <span class="lg:sidebar-collapsed:sr-only">Back</span>
    </.link>

    <div :for={{group, items} <- @groups} class="mb-4">
      <p class={["px-3 pb-1.5 lg:sidebar-collapsed:hidden", micro_label_class()]}>{group}</p>
      <ul class="space-y-0.5">
        <li :for={item <- items}>
          <.nav_link
            id={"settings-link-#{item.key}"}
            path={item.path}
            label={item.label}
            icon={item.icon}
            active={@active == item.key}
            method={item[:method]}
            external={item[:external] == true}
          />
        </li>
      </ul>
    </div>
    """
  end

  defp settings_groups(scope) do
    account = [
      %{key: :profile, label: "My profile", path: ~p"/users/profile", icon: "hero-user-circle"},
      %{
        key: :account,
        label: "Account & security",
        path: ~p"/users/settings",
        icon: "hero-lock-closed"
      }
    ]

    business =
      if business_chosen?(scope) do
        for section <- visible_settings_sections(scope) do
          %{
            key: section.key,
            label: section.short_title,
            path: ~p"/settings/#{section.key}",
            icon: section.icon
          }
        end
      else
        []
      end

    admin =
      if Scope.admin?(scope) do
        [
          %{key: :admin, label: "Admin panel", path: ~p"/admin", icon: "hero-command-line"},
          %{key: :layout, label: "Layout", path: ~p"/admin/layout", icon: "hero-squares-plus"}
        ]
      else
        []
      end

    community =
      if business_chosen?(scope),
        do: [%{key: :community, label: "Community", path: ~p"/community", icon: "hero-heart"}],
        else: []

    other =
      admin ++
        community ++
        [
          %{
            key: :documentation,
            label: "Documentation",
            path: QuantumBilling.GitHub.repo_url() <> "#readme",
            icon: "hero-book-open",
            external: true
          },
          %{
            key: :"sign-out",
            label: "Sign out",
            path: ~p"/users/log-out",
            icon: "hero-arrow-right-start-on-rectangle",
            method: "delete"
          }
        ]

    Enum.reject([{"Account", account}, {"Business", business}, {"Other", other}], fn {_, items} ->
      items == []
    end)
  end

  attr :items, :list, required: true

  defp layout_editor(assigns) do
    assigns = assign(assigns, :last, length(assigns.items) - 1)

    ~H"""
    <p class={["px-3 pb-2 lg:sidebar-collapsed:hidden", micro_label_class()]}>Arrange menu</p>
    <ul id="layout-items" class="space-y-1">
      <li
        :for={{item, index} <- Enum.with_index(@items)}
        id={"layout-item-#{item.key}"}
        data-hidden={to_string(item.hidden)}
        class={[
          "flex items-center gap-1 rounded-field border border-dashed px-2 py-1.5 transition-colors",
          if(item.hidden,
            do: "border-base-300 text-base-content/40",
            else: "border-base-content/25 bg-base-100 text-base-content"
          )
        ]}
      >
        <.icon name={item.icon} class={["size-4 shrink-0", !item.hidden && item.color]} />
        <span class={["min-w-0 flex-1 truncate text-sm", item.hidden && "line-through"]}>
          {item.label}
        </span>
        <button
          type="button"
          id={"layout-up-#{item.key}"}
          phx-click="layout_move"
          phx-value-key={item.key}
          phx-value-dir="up"
          disabled={index == 0}
          aria-label={"Move #{item.label} up"}
          class="flex size-6 items-center justify-center rounded-field text-base-content/60 hover:bg-base-200 hover:text-base-content disabled:pointer-events-none disabled:opacity-30"
        >
          <.icon name="hero-chevron-up" class="size-3.5" />
        </button>
        <button
          type="button"
          id={"layout-down-#{item.key}"}
          phx-click="layout_move"
          phx-value-key={item.key}
          phx-value-dir="down"
          disabled={index == @last}
          aria-label={"Move #{item.label} down"}
          class="flex size-6 items-center justify-center rounded-field text-base-content/60 hover:bg-base-200 hover:text-base-content disabled:pointer-events-none disabled:opacity-30"
        >
          <.icon name="hero-chevron-down" class="size-3.5" />
        </button>
        <button
          :if={item.key != :settings}
          type="button"
          id={"layout-toggle-#{item.key}"}
          phx-click="layout_toggle"
          phx-value-key={item.key}
          aria-pressed={to_string(!item.hidden)}
          aria-label={if(item.hidden, do: "Show #{item.label}", else: "Hide #{item.label}")}
          class="flex size-6 items-center justify-center rounded-field text-base-content/60 hover:bg-base-200 hover:text-base-content"
        >
          <.icon name={if(item.hidden, do: "hero-eye-slash", else: "hero-eye")} class="size-3.5" />
        </button>
        <span :if={item.key == :settings} class="size-6" aria-hidden="true" />
      </li>
    </ul>
    <p class="px-1 pt-3 text-xs text-base-content/50 lg:sidebar-collapsed:hidden">
      Settings always stays visible, so no one is locked out.
    </p>
    """
  end

  # Tolerates a nil scope. Hiding panels is cosmetic; the server enforces access.
  defp visible_settings_sections(scope) do
    sections =
      if Scope.vat?(scope),
        do: Enum.reject(SettingsComponents.sections(), &SettingsLive.gst_only?(&1.key)),
        else: SettingsComponents.sections()

    if Scope.owner?(scope) do
      sections ++
        [
          %{key: :"data-model", short_title: "Data model", icon: "hero-table-cells"},
          %{key: :team, short_title: "Team", icon: "hero-user-group"},
          %{key: :"api-keys", short_title: "API keys", icon: "hero-key"},
          %{key: :webhooks, short_title: "Webhooks", icon: "hero-signal"},
          %{key: :"audit-logs", short_title: "Audit log", icon: "hero-clipboard-document-list"}
        ]
    else
      Enum.reject(sections, &SettingsLive.owner_only?(&1.key))
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

  defp notification_tone("success"),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"

  defp notification_tone("warning"),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300"

  defp notification_tone("error"),
    do: "bg-rose-50 text-rose-700 dark:bg-rose-950 dark:text-rose-300"

  defp notification_tone(_info), do: "bg-base-200 text-base-content/60"

  defp user_designation(%{user: %{designation: title}}) when is_binary(title) and title != "",
    do: title

  defp user_designation(_scope), do: nil

  # The India GST tools have no meaning for a VAT business.
  @gst_only_nav [:e_way_bills, :hsn_finder]

  # The main menu in the super admin's saved order, without hidden items.
  defp nav_items(scope) do
    layout_items()
    |> Enum.reject(&(&1.hidden or (Scope.vat?(scope) and &1.key in @gst_only_nav)))
  end

  @doc """
  Every main menu item in the saved order, each with `:hidden`. Items added
  since the layout was saved come last, shown. Settings is never hidden.
  """
  def layout_items(saved \\ QuantumBilling.InstallationSettings.nav_layout()) do
    items = nav_items()
    by_key = Map.new(items, &{Atom.to_string(&1.key), &1})

    ordered =
      for %{"key" => key} = entry <- saved,
          item = Map.get(by_key, key),
          item != nil,
          uniq: true do
        Map.put(item, :hidden, entry["hidden"] == true and item.key != :settings)
      end

    seen = MapSet.new(ordered, & &1.key)
    ordered ++ for(item <- items, item.key not in seen, do: Map.put(item, :hidden, false))
  end

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
        key: :quotations,
        label: "Quotations",
        path: ~p"/quotations",
        icon: "hero-clipboard-document-list",
        color: "text-violet-600 dark:text-violet-400"
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
        path: ~p"/settings/company",
        icon: "hero-cog-6-tooth",
        color: "text-rose-600 dark:text-rose-400"
      }
    ]
  end

  @doc """
  Renders the shell for one-step-at-a-time screens: the business picker, its
  success screen and onboarding. No sidebar; a progress bar when `steps` is
  set, and a `:footer` slot.
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :step, :integer, default: nil, doc: "the current step, from 1"
  attr :steps, :integer, default: nil, doc: "how many steps the flow has; no bar when nil"

  slot :inner_block, required: true
  slot :footer, doc: "the Back / Next row"

  def focus(assigns) do
    ~H"""
    <.skip_link />
    <div
      id="focus-shell"
      class="relative isolate flex min-h-dvh flex-col bg-base-100 text-base-content"
    >
      <header class="flex items-center justify-between gap-4 border-b border-base-300 px-5 py-3 sm:px-8">
        <.brand_mark />

        <.action_menu
          :if={@current_scope && @current_scope.user}
          id="focus-user-menu"
          label="User account options"
          trigger_class="flex items-center gap-2 rounded-full py-1 pl-1 pr-2.5 transition-colors hover:bg-base-content/5"
          menu_class="z-20 mt-2 w-48"
        >
          <:trigger>
            <span class={["bg-base-content text-base-100", avatar_class()]}>
              {user_initials(@current_scope)}
            </span>
            <span class="hidden max-w-40 truncate text-sm font-medium sm:block">
              {user_name(@current_scope)}
            </span>
            <.icon name="hero-chevron-down" class="size-3.5 text-base-content/45" />
          </:trigger>
          <li>
            <.link
              role="menuitem"
              href={~p"/users/log-out"}
              method="delete"
              id="focus-sign-out"
            >
              Sign out
            </.link>
          </li>
        </.action_menu>
      </header>

      <div :if={@steps} id="focus-progress" class="mx-auto w-full max-w-5xl px-5 pt-6 sm:px-8">
        <div
          role="progressbar"
          aria-label={"Step #{@step} of #{@steps}"}
          aria-valuemin="1"
          aria-valuemax={@steps}
          aria-valuenow={@step}
          class="flex gap-1.5"
        >
          <span
            :for={index <- 1..@steps}
            class={[
              "h-1 flex-1 rounded-full transition-colors duration-500 motion-reduce:transition-none",
              if(index <= (@step || 0), do: "bg-base-content", else: "bg-base-300")
            ]}
          />
        </div>
      </div>

      <main
        id="main-content"
        tabindex="-1"
        class="flex flex-1 flex-col items-center px-4 py-8 focus:outline-none sm:px-8 sm:py-10"
      >
        {render_slot(@inner_block)}
      </main>

      <footer
        :if={@footer != []}
        class="sticky bottom-0 border-t border-base-300 bg-base-100"
      >
        <div class="mx-auto flex w-full max-w-5xl items-center justify-between gap-3 px-5 py-4 sm:px-8">
          {render_slot(@footer)}
        </div>
      </footer>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc "The forward button on a `focus/1` screen: Next, Continue, Finish."
  def focus_next_class do
    "inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-base-content px-5 " <>
      "text-sm font-medium text-base-100 transition-colors hover:bg-base-content/85 " <>
      "disabled:pointer-events-none disabled:opacity-35 aria-disabled:pointer-events-none " <>
      "aria-disabled:opacity-35"
  end

  @doc "The quiet companion to `focus_next_class/0`: Back, Skip."
  def focus_back_class do
    "inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-base-300 " <>
      "bg-base-100 px-4 text-sm font-medium text-base-content/70 transition-colors " <>
      "hover:bg-base-200 hover:text-base-content"
  end

  @doc "Renders the sign-in and sign-up shell: a centred form with branding in the corners."
  attr :flash, :map, required: true, doc: "the map of flash messages"

  slot :top_link, doc: "the cross-link shown in the top-right corner"
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <.skip_link />
    <div class="relative flex min-h-screen flex-col items-center justify-center bg-base-100 px-4 pt-20 pb-32">
      <div class="absolute left-4 top-4 flex items-center gap-2 text-lg font-semibold tracking-tight text-base-content md:left-8 md:top-8">
        <.icon name="hero-receipt-percent" class="size-6" /> QuantumBilling
      </div>

      <div
        :if={@top_link != []}
        class="absolute right-4 top-4 text-sm font-medium text-base-content md:right-8 md:top-8"
      >
        {render_slot(@top_link)}
      </div>

      <main
        id="main-content"
        tabindex="-1"
        class="mx-auto flex w-full flex-col justify-center space-y-6 focus:outline-none sm:w-[350px]"
      >
        {render_slot(@inner_block)}
      </main>

      <footer class="absolute inset-x-0 bottom-6 flex justify-center px-4">
        <a
          id="osworks-credit"
          href="https://osworks.in"
          target="_blank"
          rel="noopener noreferrer"
          class="group flex flex-col items-center gap-2 rounded-field px-2 py-1 text-center text-xs text-base-content/60 transition-colors hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
        >
          <QuantumBillingWeb.OSWorks.mark class="size-8 text-base-content transition-transform duration-300 group-hover:scale-110 motion-reduce:transition-none" />
          <span>
            QuantumBilling is a community driven project under <span class="font-semibold tracking-wide text-base-content">OSWORKS</span>.
          </span>
          <span class="sr-only">(opens in a new tab)</span>
        </a>
      </footer>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc "Renders the shell for public legal pages (terms, privacy), without the sidebar."
  attr :flash, :map, required: true
  attr :title, :string, required: true
  attr :current_scope, :map, default: nil
  attr :other_doc_path, :string, required: true
  attr :other_doc_label, :string, required: true
  attr :effective_on, Date, required: true
  attr :updated_on, Date, required: true
  attr :summary, :string, default: nil

  slot :inner_block, required: true

  def legal(assigns) do
    ~H"""
    <.skip_link />
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

      <main
        id="main-content"
        tabindex="-1"
        class="mx-auto w-full max-w-3xl flex-1 px-6 py-12 focus:outline-none"
      >
        <h1 class="text-3xl font-semibold tracking-tight text-base-content">{@title}</h1>

        <p id="legal-dates" class="mt-2 text-sm text-base-content/60">
          Effective {legal_date(@effective_on)} · Last updated {legal_date(@updated_on)}
        </p>

        <p :if={@summary} class="mt-6 text-sm leading-relaxed text-base-content/70">
          {@summary}
        </p>

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

  defp legal_date(%Date{} = date), do: Calendar.strftime(date, "%-d %B %Y")

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
  The "Skip to content" link (WCAG 2.4.1). Hidden until focused, so the first
  Tab on any page offers a jump past the navigation to `#main-content`.
  """
  def skip_link(assigns) do
    ~H"""
    <a
      id="skip-link"
      href="#main-content"
      class={[
        "sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[100]",
        "focus:rounded-md focus:border focus:border-base-300 focus:bg-base-100 focus:px-4 focus:py-2",
        "focus:text-sm focus:font-medium focus:text-base-content focus:shadow-lg",
        "focus:outline-2 focus:outline-offset-2 focus:outline-base-content"
      ]}
    >
      Skip to content
    </a>
    """
  end

  @doc "Shows the flash group with standard titles and content."
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.sign_in_request_prompt request={Phoenix.Flash.get(@flash, :sign_in_request)} />
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
  "One device at a time": asks this device whether to let another one sign in.
  Carried in the flash so every page shows it; see `UserAuth.watch_own_account/1`.
  """
  attr :request, :map, default: nil

  def sign_in_request_prompt(%{request: %{"id" => _}} = assigns) do
    ~H"""
    <div
      id="sign-in-request-prompt"
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="sign-in-request-title"
      aria-describedby="sign-in-request-body"
      class="fixed inset-0 z-[60] flex items-end justify-center bg-base-content/30 p-4 backdrop-blur-[2px] sm:items-center"
    >
      <div class="w-full max-w-sm rounded-2xl border border-base-300 bg-base-100 p-5 shadow-xl motion-safe:animate-[sign-in-request-pop_180ms_ease-out]">
        <div class="flex items-start gap-3">
          <span class="grid size-9 shrink-0 place-items-center rounded-full bg-warning/15 text-warning">
            <.icon name="hero-device-phone-mobile" class="size-5" />
          </span>
          <div class="min-w-0">
            <h2 id="sign-in-request-title" class="text-sm font-semibold text-base-content">
              Someone is signing in to your account
            </h2>
            <p id="sign-in-request-body" class="mt-1 text-sm text-base-content/70">
              On
              <span class="font-medium text-base-content">{@request["device"]}</span><span :if={
                @request["ip"]
              }>, {@request["ip"]}</span>. Your account can be used on one device at a time.
            </p>
          </div>
        </div>

        <div class="mt-5 grid grid-cols-2 gap-2">
          <button
            id="sign-in-request-sign-out"
            type="button"
            phx-click="sign_in_request_answer"
            phx-value-id={@request["id"]}
            phx-value-answer="approve"
            phx-disable-with="Signing out…"
            class="inline-flex h-9 cursor-pointer items-center justify-center rounded-lg border border-base-300 px-3 text-sm font-medium text-base-content transition hover:bg-base-200 active:scale-[0.98]"
          >
            Sign out here
          </button>
          <button
            id="sign-in-request-continue"
            type="button"
            phx-click="sign_in_request_answer"
            phx-value-id={@request["id"]}
            phx-value-answer="deny"
            phx-disable-with="Continuing…"
            autofocus
            class="inline-flex h-9 cursor-pointer items-center justify-center rounded-lg bg-primary px-3 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110 active:scale-[0.98]"
          >
            Continue
          </button>
        </div>

        <p class="mt-3 text-xs text-base-content/55">
          If this isn't you, choose Continue and change your password.
        </p>
      </div>
    </div>
    """
  end

  def sign_in_request_prompt(assigns), do: ~H""

  @doc "Light, dark and system theme toggle. `root.html.heex` applies the theme before paint."
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

  @doc """
  The in-app confirmation for `data-confirm`, filled and opened by
  `assets/js/confirm_dialog.js`. Rendered once by the root layout, outside the
  LiveView container, so live navigation never replaces it. `data-tone` on the
  dialog switches between the danger and neutral styles.
  """
  def confirm_dialog(assigns) do
    ~H"""
    <dialog
      id="confirm-dialog"
      data-tone="danger"
      aria-labelledby="confirm-dialog-title"
      aria-describedby="confirm-dialog-body"
      class="qb-confirm group m-auto w-[calc(100%-2rem)] max-w-md rounded-box border border-base-300 bg-base-100 p-0 text-base-content shadow-2xl backdrop:bg-base-content/35 backdrop:backdrop-blur-[2px]"
    >
      <div class="flex items-start gap-3.5 p-5">
        <span class={[
          "flex size-10 shrink-0 items-center justify-center rounded-full ring-4",
          "bg-error/10 text-error ring-error/5",
          "group-data-[tone=neutral]:bg-primary/10 group-data-[tone=neutral]:text-primary",
          "group-data-[tone=neutral]:ring-primary/5"
        ]}>
          <.icon
            name="hero-exclamation-triangle"
            class="size-5 group-data-[tone=neutral]:hidden"
          />
          <.icon
            name="hero-question-mark-circle"
            class="hidden size-5 group-data-[tone=neutral]:block"
          />
        </span>

        <div class="min-w-0 flex-1 pt-0.5">
          <h2
            id="confirm-dialog-title"
            class="text-sm font-semibold tracking-tight break-words"
          >
            Are you sure?
          </h2>

          <p
            id="confirm-dialog-body"
            class="mt-1.5 text-sm leading-relaxed text-base-content/60 break-words"
          >
          </p>
        </div>
      </div>

      <div class="flex flex-col-reverse gap-2 rounded-b-box border-t border-base-300 bg-base-200/50 px-5 py-3 sm:flex-row sm:justify-end">
        <button
          type="button"
          id="confirm-dialog-cancel"
          class="inline-flex h-9 items-center justify-center rounded-field border border-base-300 bg-base-100 px-3.5 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-base-content/20"
        >
          Cancel
        </button>

        <button
          type="button"
          id="confirm-dialog-ok"
          class={[
            "inline-flex h-9 items-center justify-center rounded-field px-3.5 text-sm font-medium",
            "transition-colors",
            "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-offset-base-100",
            "bg-error text-error-content hover:bg-error/90 focus-visible:ring-error/40",
            "group-data-[tone=neutral]:bg-primary group-data-[tone=neutral]:text-primary-content",
            "group-data-[tone=neutral]:hover:bg-primary/90 group-data-[tone=neutral]:focus-visible:ring-primary/40"
          ]}
        >
          Confirm
        </button>
      </div>
    </dialog>
    """
  end
end
