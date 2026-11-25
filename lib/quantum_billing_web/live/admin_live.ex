defmodule QuantumBillingWeb.AdminLive do
  @moduledoc """
  The super admin's Admin Panel, for the whole installation rather than one
  business. Tabs:

    * General – the version, the administrators, recent users and the
      businesses with the most members.
    * Config – the environment variables the app reads, secrets masked.
    * Health – the database, background jobs, email, calendar and storage,
      the upgrade status and maintenance mode.
    * Layout – arranges the main menu for everyone (see `Layouts.layout_items/1`).

  Mounted behind `:require_admin`, so anyone else gets a 404.
  """
  use QuantumBillingWeb, :live_view

  require Logger

  alias QuantumBilling.{Admin, InstallationSettings}

  @tabs [
    general: {"General", "hero-home"},
    config: {"Config", "hero-adjustments-horizontal"},
    health: {"Health", "hero-heart"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin panel")
     |> assign(:tabs, @tabs)
     |> assign(:layout_draft, nil)
     |> stream_configure(:config_vars, dom_id: &"config-#{&1.name}")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, load(socket, socket.assigns.live_action)}
  end

  defp load(socket, :general) do
    socket
    |> assign(:admins, Admin.admins())
    |> assign(:user_search, to_form(%{"q" => ""}, as: :users))
    |> assign(:business_search, to_form(%{"q" => ""}, as: :businesses))
    |> stream_users("")
    |> stream_businesses("")
    |> assign_async(:version, fn -> {:ok, %{version: Admin.version_info()}} end)
  end

  defp load(socket, :config) do
    socket
    |> assign(:config_search, to_form(%{"q" => ""}, as: :config))
    |> stream_config("")
  end

  defp load(socket, :health) do
    socket
    |> assign(:checks, Admin.health_checks())
    |> assign(:upgrade, Admin.upgrade_status())
    |> assign(:maintenance?, InstallationSettings.maintenance?())
  end

  defp load(socket, :layout) do
    assign(socket, :layout_draft, Layouts.layout_items())
  end

  defp stream_users(socket, search) do
    users = Admin.recent_users(search)

    socket
    |> assign(:users_count, length(users))
    |> stream(:users, users, reset: true)
  end

  defp stream_businesses(socket, search) do
    businesses = Admin.top_businesses(search)

    socket
    |> assign(:businesses_count, length(businesses))
    |> stream(:businesses, businesses, reset: true)
  end

  defp stream_config(socket, search) do
    vars = Admin.config_vars(search)

    socket
    |> assign(:config_count, length(vars))
    |> stream(:config_vars, vars, reset: true)
  end

  @impl true
  def handle_event("search_users", %{"users" => %{"q" => q}}, socket) do
    {:noreply,
     socket
     |> assign(:user_search, to_form(%{"q" => q}, as: :users))
     |> stream_users(q)}
  end

  def handle_event("search_businesses", %{"businesses" => %{"q" => q}}, socket) do
    {:noreply,
     socket
     |> assign(:business_search, to_form(%{"q" => q}, as: :businesses))
     |> stream_businesses(q)}
  end

  def handle_event("search_config", %{"config" => %{"q" => q}}, socket) do
    {:noreply,
     socket
     |> assign(:config_search, to_form(%{"q" => q}, as: :config))
     |> stream_config(q)}
  end

  def handle_event("refresh_health", _params, socket) do
    {:noreply, load(socket, :health)}
  end

  def handle_event("toggle_maintenance", _params, socket) do
    on? = not socket.assigns.maintenance?
    {:ok, _settings} = InstallationSettings.set_maintenance(InstallationSettings.get(), on?)

    Logger.warning(
      "[security] actor=#{socket.assigns.current_scope.user.email} " <>
        "turned maintenance mode #{if on?, do: "on", else: "off"}"
    )

    {:noreply,
     socket
     |> assign(:maintenance?, on?)
     |> put_flash(
       :info,
       if(on?,
         do: "Maintenance mode is on. Only super admins can use the app.",
         else: "Maintenance mode is off."
       )
     )}
  end

  def handle_event("layout_move", %{"key" => key, "dir" => dir}, socket) do
    items = socket.assigns.layout_draft
    index = Enum.find_index(items, &(Atom.to_string(&1.key) == key))
    target = if dir == "up", do: index && index - 1, else: index && index + 1

    items =
      if index && target in 0..(length(items) - 1)//1 do
        item = Enum.at(items, index)
        items |> List.delete_at(index) |> List.insert_at(target, item)
      else
        items
      end

    {:noreply, assign(socket, :layout_draft, items)}
  end

  def handle_event("layout_toggle", %{"key" => key}, socket) do
    items =
      Enum.map(socket.assigns.layout_draft, fn item ->
        if Atom.to_string(item.key) == key and item.key != :settings,
          do: %{item | hidden: not item.hidden},
          else: item
      end)

    {:noreply, assign(socket, :layout_draft, items)}
  end

  def handle_event("layout_save", _params, socket) do
    entries =
      for item <- socket.assigns.layout_draft do
        %{"key" => Atom.to_string(item.key), "hidden" => item.hidden}
      end

    {:ok, _settings} = InstallationSettings.update_layout(InstallationSettings.get(), entries)

    {:noreply,
     socket
     |> put_flash(:info, "Menu layout saved for everyone.")
     |> push_navigate(to: ~p"/admin")}
  end

  def handle_event("layout_cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/admin")}
  end

  @impl true
  def render(%{live_action: :layout} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      layout_draft={@layout_draft}
    >
      <div id="layout-help" class="mx-auto w-full max-w-xl px-2 py-10 text-center">
        <span class="mx-auto flex size-11 items-center justify-center rounded-full bg-base-100 ring-1 ring-base-300">
          <.icon name="hero-squares-plus" class="size-5 text-base-content/70" />
        </span>
        <h1 class="mt-4 text-lg font-semibold tracking-tight">Arrange the main menu</h1>
        <p class="mt-1.5 text-sm text-base-content/60">
          Use the arrows in the sidebar to change the order, and the eye to hide an item.
          Hidden pages still work from a link; they are only left out of the menu.
          Press Save in the banner to apply it for every user.
        </p>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      sidebar={:settings}
      active_sub={:admin}
    >
      <div class="mx-auto w-full max-w-4xl px-1 py-4 sm:px-4">
        <.header>
          Admin panel
          <:subtitle>Settings for this whole installation, across every business.</:subtitle>
        </.header>

        <nav
          id="admin-tabs"
          aria-label="Admin panel"
          class="mb-6 mt-3 flex gap-1 overflow-x-auto border-b border-base-300"
        >
          <.link
            :for={{key, {label, icon}} <- @tabs}
            id={"admin-tab-#{key}"}
            patch={tab_path(key)}
            aria-current={if(@live_action == key, do: "page")}
            class={[
              "-mb-px flex shrink-0 items-center gap-1.5 border-b-2 px-3 py-2 text-sm transition-colors",
              if(@live_action == key,
                do: "border-base-content font-medium text-base-content",
                else: "border-transparent text-base-content/60 hover:text-base-content"
              )
            ]}
          >
            <.icon name={icon} class="size-4" />
            {label}
          </.link>
        </nav>

        <%= case @live_action do %>
          <% :general -> %>
            <.general {assigns} />
          <% :config -> %>
            <.config {assigns} />
          <% :health -> %>
            <.health {assigns} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp tab_path(:general), do: ~p"/admin"
  defp tab_path(:config), do: ~p"/admin/config"
  defp tab_path(:health), do: ~p"/admin/health"

  defp general(assigns) do
    ~H"""
    <section id="admin-about" class="mb-8">
      <.section_title title="About" subtitle="The version this server runs." />
      <.card padding="p-0" class="divide-y divide-base-300">
        <.row label="Current version">
          <span id="admin-current-version" class="font-mono text-sm">
            {QuantumBilling.Admin.current_version()}
          </span>
        </.row>
        <.row label="Latest version">
          <.async_result :let={version} assign={@version}>
            <:loading>
              <span class="inline-block h-4 w-16 animate-pulse rounded bg-base-200" />
            </:loading>
            <:failed><span class="text-sm text-base-content/50">Unknown</span></:failed>
            <span class="flex items-center gap-2">
              <span id="admin-latest-version" class="font-mono text-sm">
                {version.latest || "Unknown"}
              </span>
              <.pill :if={version.update?} tone={:warn}>Update available</.pill>
              <.pill :if={version.latest && !version.update?} tone={:ok}>Up to date</.pill>
            </span>
          </.async_result>
        </.row>
      </.card>
    </section>

    <section id="admin-admins" class="mb-8">
      <.section_title
        title="Administrators"
        subtitle="Super admins see this panel. Grant or revoke with mix qb.admin.grant."
      />
      <.card padding="p-0" class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr class={table_head_class()}>
              <th>Name</th>
              <th>Email</th>
              <th class="w-32 text-right">Admin panel</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={admin <- @admins} id={"admin-#{admin.id}"} class={table_row_class()}>
              <td class="font-medium">{admin.full_name || admin.username || "—"}</td>
              <td class="text-base-content/70">{admin.email}</td>
              <td class="text-right">
                <.icon name="hero-check" class="size-4 text-emerald-600 dark:text-emerald-400" />
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </section>

    <section id="admin-users" class="mb-8">
      <.section_title title="Recent users" subtitle="The newest sign-ups, by email or name." />
      <.form for={@user_search} id="user-search-form" phx-change="search_users" class="mb-2">
        <.input
          field={@user_search[:q]}
          type="search"
          placeholder="Search users"
          phx-debounce="250"
          autocomplete="off"
        />
      </.form>
      <.card padding="p-0" class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr class={table_head_class()}>
              <th>User</th>
              <th class="w-28 text-right">Businesses</th>
              <th class="w-36 text-right">Joined</th>
            </tr>
          </thead>
          <tbody id="admin-user-rows" phx-update="stream">
            <tr :for={{id, user} <- @streams.users} id={id} class={table_row_class()}>
              <td>
                <div class="flex items-center gap-2.5">
                  <span class={["shrink-0 bg-base-200 text-base-content/70", avatar_class()]}>
                    {initials(user.name || user.email)}
                  </span>
                  <span class="min-w-0">
                    <span class="block truncate font-medium">{user.name || user.email}</span>
                    <span :if={user.name} class="block truncate text-xs text-base-content/50">
                      {user.email}
                    </span>
                  </span>
                </div>
              </td>
              <td class="text-right tabular-nums">{user.business_count}</td>
              <td class="text-right text-base-content/60">
                {Calendar.strftime(user.joined_at, "%d %b %Y")}
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@users_count == 0} class="px-4 py-6 text-center text-sm text-base-content/50">
          No users match.
        </p>
      </.card>
    </section>

    <section id="admin-businesses">
      <.section_title title="Top businesses" subtitle="Active businesses with the most members." />
      <.form
        for={@business_search}
        id="business-search-form"
        phx-change="search_businesses"
        class="mb-2"
      >
        <.input
          field={@business_search[:q]}
          type="search"
          placeholder="Search businesses"
          phx-debounce="250"
          autocomplete="off"
        />
      </.form>
      <.card padding="p-0" class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr class={table_head_class()}>
              <th>Business</th>
              <th class="w-28 text-right">Members</th>
            </tr>
          </thead>
          <tbody id="admin-business-rows" phx-update="stream">
            <tr :for={{id, business} <- @streams.businesses} id={id} class={table_row_class()}>
              <td>
                <span class="block font-medium">{business.name}</span>
                <span class="block text-xs text-base-content/50">{business.slug}</span>
              </td>
              <td class="text-right tabular-nums">{business.member_count}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@businesses_count == 0} class="px-4 py-6 text-center text-sm text-base-content/50">
          No businesses match.
        </p>
      </.card>
    </section>
    """
  end

  defp config(assigns) do
    ~H"""
    <section id="admin-config">
      <.section_title
        title="Configuration"
        subtitle="Environment variables read at boot. Change them on the server and restart; secrets are never shown."
      />
      <.form for={@config_search} id="config-search-form" phx-change="search_config" class="mb-2">
        <.input
          field={@config_search[:q]}
          type="search"
          placeholder="Search variables"
          phx-debounce="150"
          autocomplete="off"
        />
      </.form>
      <.card padding="p-0" class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr class={table_head_class()}>
              <th>Name</th>
              <th class="hidden sm:table-cell">Description</th>
              <th class="w-48 text-right">Value</th>
            </tr>
          </thead>
          <tbody id="config-rows" phx-update="stream">
            <tr :for={{id, var} <- @streams.config_vars} id={id} class={table_row_class()}>
              <td class="font-mono text-xs font-medium">{var.name}</td>
              <td class="hidden text-base-content/60 sm:table-cell">{var.description}</td>
              <td class="max-w-48 truncate text-right font-mono text-xs">
                <span :if={var.value && var.secret?} class="tracking-widest text-base-content/60">
                  {var.value}
                </span>
                <span :if={var.value && !var.secret?} title={var.value}>{var.value}</span>
                <span :if={is_nil(var.value)} class="font-sans text-base-content/40">Not set</span>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@config_count == 0} class="px-4 py-6 text-center text-sm text-base-content/50">
          No variables match.
        </p>
      </.card>
    </section>
    """
  end

  defp health(assigns) do
    ~H"""
    <section id="admin-health" class="mb-8">
      <.section_title title="Status" subtitle="Checked when this page opens.">
        <:actions>
          <button
            type="button"
            id="health-refresh"
            phx-click="refresh_health"
            class={secondary_button_class()}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </button>
        </:actions>
      </.section_title>
      <.card padding="p-0" class="divide-y divide-base-300">
        <div
          :for={check <- @checks}
          id={"health-#{check.key}"}
          data-status={check.status}
          class="flex items-center justify-between gap-4 px-4 py-3"
        >
          <span class="min-w-0">
            <span class="block text-sm font-medium">{check.name}</span>
            <span class="block truncate text-xs text-base-content/55">{check.detail}</span>
          </span>
          <.pill tone={status_tone(check.status)}>{status_label(check.status)}</.pill>
        </div>
      </.card>
    </section>

    <section id="admin-upgrade" class="mb-8">
      <.section_title title="Upgrade status" subtitle="Whether the database matches this version." />
      <.card padding="p-0" class="divide-y divide-base-300">
        <.row label="Version">
          <span class="font-mono text-sm">{@upgrade.version}</span>
        </.row>
        <.row label="Installation database">
          <.pill :if={@upgrade.public_pending == 0} tone={:ok}>Up to date</.pill>
          <.pill :if={@upgrade.public_pending > 0} tone={:warn}>
            {@upgrade.public_pending} migrations pending
          </.pill>
        </.row>
        <.row label="Business databases">
          <span class="flex items-center gap-2">
            <span class="text-sm tabular-nums text-base-content/70">
              {@upgrade.businesses_current} of {@upgrade.businesses_total}
            </span>
            <.pill tone={
              if(@upgrade.businesses_current == @upgrade.businesses_total, do: :ok, else: :warn)
            }>
              {if(@upgrade.businesses_current == @upgrade.businesses_total,
                do: "Up to date",
                else: "Run mix ecto.migrate"
              )}
            </.pill>
          </span>
        </.row>
      </.card>
    </section>

    <section id="admin-maintenance">
      <.section_title
        title="Maintenance mode"
        subtitle="Signs everyone but super admins out of the app and shows them a maintenance page."
      />
      <.card class="flex items-center justify-between gap-4" padding="px-4 py-3">
        <span class="text-sm">
          {if @maintenance?, do: "On — only super admins can work", else: "Off"}
        </span>
        <button
          type="button"
          id="maintenance-toggle"
          role="switch"
          aria-checked={to_string(@maintenance?)}
          aria-label="Maintenance mode"
          phx-click="toggle_maintenance"
          data-confirm={
            if(!@maintenance?,
              do:
                "Turn on maintenance mode? Everyone but super admins is shut out until you turn it off."
            )
          }
          class={[
            "relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors",
            "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content",
            if(@maintenance?, do: "bg-amber-500", else: "bg-base-300")
          ]}
        >
          <span class={[
            "inline-block size-5 rounded-full bg-white shadow transition-transform motion-reduce:transition-none",
            if(@maintenance?, do: "translate-x-5.5", else: "translate-x-0.5")
          ]} />
        </button>
      </.card>
    </section>
    """
  end

  defp status_tone(:ok), do: :ok
  defp status_tone(:degraded), do: :warn
  defp status_tone(:off), do: :muted

  defp status_label(:ok), do: "Operational"
  defp status_label(:degraded), do: "Degraded"
  defp status_label(:off), do: "Not configured"

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  defp section_title(assigns) do
    ~H"""
    <div class="mb-2 flex items-end justify-between gap-4">
      <div>
        <h2 class="text-sm font-semibold">{@title}</h2>
        <p :if={@subtitle} class="text-xs text-base-content/55">{@subtitle}</p>
      </div>
      {render_slot(@actions)}
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 px-4 py-3">
      <span class="text-sm text-base-content/70">{@label}</span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :tone, :atom, values: [:ok, :warn, :muted], default: :muted
  slot :inner_block, required: true

  defp pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium",
      case @tone do
        :ok -> "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
        :warn -> "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300"
        :muted -> "bg-base-200 text-base-content/60"
      end
    ]}>
      <span class={[
        "size-1.5 rounded-full",
        case @tone do
          :ok -> "bg-emerald-500"
          :warn -> "bg-amber-500"
          :muted -> "bg-base-content/30"
        end
      ]} />
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp initials(text) do
    text
    |> String.split(~r/[\s@._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end
end
