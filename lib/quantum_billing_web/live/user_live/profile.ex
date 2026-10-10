defmodule QuantumBillingWeb.UserLive.Profile do
  @moduledoc """
  The signed-in user's profile: who they are, how to reach them, and what they
  have been doing in the application.

  The banner is a landscape drawn from a seed (`QuantumBillingWeb.SceneBanner`).
  Until the user shuffles it the seed is their id, so everybody has a scene of
  their own from the start without anything being stored.

  Editing lives on Account Settings; this page only shows the profile.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.SceneBanner

  alias QuantumBilling.Accounts
  alias QuantumBilling.Audit
  alias QuantumBilling.Settings

  @activity_limit 8

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    organization = Settings.get_organization()

    {:ok,
     socket
     |> assign(:page_title, "My Profile")
     |> assign(:active_nav, nil)
     |> assign(:organization, organization)
     |> assign(:location, location(organization))
     |> assign(:activity, Audit.recent_for_user(user.id, @activity_limit))}
  end

  @impl true
  def handle_event("shuffle_banner", _params, socket) do
    scope = socket.assigns.current_scope

    case Accounts.shuffle_banner(scope.user) do
      {:ok, user} ->
        {:noreply, assign(socket, :current_scope, %{scope | user: user})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "A new scene could not be saved.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.card id="profile-hero" padding="p-0" class="mb-3 overflow-hidden">
        <div class="group/banner relative h-44 overflow-hidden bg-base-300 sm:h-56">
          <%!-- Keyed by seed so a shuffle replaces the SVG and replays the fade. --%>
          <div
            id={"profile-banner-frame-#{banner_seed(@current_scope.user)}"}
            class="absolute inset-0 animate-[qb-chart-fade_500ms_ease-out]"
          >
            <.scene_banner
              id="profile-banner"
              seed={banner_seed(@current_scope.user)}
              class="block size-full"
            />
          </div>

          <button
            id="banner-shuffle"
            type="button"
            phx-click="shuffle_banner"
            class="absolute bottom-3 right-3 inline-flex h-8 items-center gap-1.5 rounded-full border border-white/25 bg-black/30 px-3 text-xs font-medium text-white backdrop-blur-md transition-all hover:bg-black/45 active:scale-95 phx-click-loading:opacity-60"
          >
            <.icon name="hero-sparkles" class="size-3.5" /> New scene
          </button>
        </div>

        <div class="relative px-4 pb-4 sm:px-6">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:gap-5">
            <span
              id="profile-avatar"
              class="-mt-14 flex size-28 shrink-0 items-center justify-center rounded-full bg-base-300 text-3xl font-semibold text-base-content shadow-lg ring-4 ring-base-100"
            >
              {initials(@current_scope.user)}
            </span>

            <div class="min-w-0 flex-1 sm:pb-1">
              <h1 id="profile-name" class="truncate text-xl font-semibold tracking-tight">
                {display_name(@current_scope.user)}
              </h1>
              <p :if={present?(@current_scope.user.designation)} class="text-sm text-base-content/60">
                {@current_scope.user.designation}
              </p>
              <div class="mt-1.5 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/55">
                <span :if={@location} class="inline-flex items-center gap-1">
                  <.icon name="hero-map-pin" class="size-3.5" /> {@location}
                </span>
                <span
                  :if={present?(@organization.company_name)}
                  class="inline-flex items-center gap-1"
                >
                  <.icon name="hero-building-office-2" class="size-3.5" /> {@organization.company_name}
                </span>
                <span class="inline-flex items-center gap-1">
                  <.icon name="hero-identification" class="size-3.5" />
                  {role_label(@current_scope.user.role)}
                </span>
              </div>
            </div>

            <div class="absolute right-3 top-3 sm:static sm:pb-1">
              <div class="dropdown dropdown-end">
                <div
                  id="profile-menu"
                  tabindex="0"
                  role="button"
                  class={[row_action_class(), "size-9"]}
                  aria-label="Profile options"
                >
                  <.icon name="hero-ellipsis-horizontal" class="size-5" />
                </div>
                <ul
                  tabindex="0"
                  class="dropdown-content menu z-20 mt-1 w-56 rounded-box border border-base-300 bg-base-100 p-1.5 text-sm shadow-lg"
                >
                  <li>
                    <button id="profile-menu-shuffle" type="button" phx-click="shuffle_banner">
                      <.icon name="hero-sparkles" class="size-4" /> New banner scene
                    </button>
                  </li>
                  <li>
                    <.link navigate={~p"/users/settings"}>
                      <.icon name="hero-pencil-square" class="size-4" /> Edit profile
                    </.link>
                  </li>
                  <li>
                    <.link navigate={~p"/users/settings?#{[tab: :password]}"}>
                      <.icon name="hero-lock-closed" class="size-4" /> Password &amp; security
                    </.link>
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </div>
      </.card>

      <div class="grid grid-cols-1 gap-3 lg:grid-cols-[18rem_1fr]">
        <.card id="profile-contact" padding="p-4" class="h-fit space-y-4">
          <div class="space-y-2.5">
            <h2 class={micro_label_class()}>Contact</h2>

            <.contact_row icon="hero-phone" label="Phone" value={@current_scope.user.phone} />
            <.contact_row icon="hero-envelope" label="Email" value={@current_scope.user.email} />
          </div>

          <.link
            id="profile-edit"
            navigate={~p"/users/settings"}
            class={[action_button_class(), "w-full justify-center"]}
          >
            <.icon name="hero-pencil-square" class="size-4" /> Edit profile
          </.link>

          <div class="space-y-2.5 border-t border-base-300 pt-4">
            <h2 class={micro_label_class()}>Account</h2>

            <div class="flex items-center justify-between gap-2 text-sm">
              <span class="text-base-content/60">Two-factor</span>
              <span
                id="profile-2fa"
                class={[
                  "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium",
                  if(@current_scope.user.totp_confirmed_at,
                    do: "bg-emerald-500/10 text-emerald-600",
                    else: "bg-amber-500/10 text-amber-600"
                  )
                ]}
              >
                <.icon
                  name={
                    if @current_scope.user.totp_confirmed_at,
                      do: "hero-shield-check",
                      else: "hero-shield-exclamation"
                  }
                  class="size-3.5"
                />
                {if @current_scope.user.totp_confirmed_at, do: "On", else: "Off"}
              </span>
            </div>

            <div class="flex items-center justify-between gap-2 text-sm">
              <span class="text-base-content/60">Member since</span>
              <span>{format_date(DateTime.to_date(@current_scope.user.inserted_at))}</span>
            </div>
          </div>
        </.card>

        <div class="space-y-3">
          <.card id="profile-about" padding="p-4">
            <h2 class="text-sm font-semibold tracking-tight">About</h2>

            <dl class="mt-3 grid grid-cols-1 gap-3 text-sm sm:grid-cols-2">
              <.about_item label="Full name" value={@current_scope.user.full_name} />
              <.about_item label="Designation" value={@current_scope.user.designation} />
              <.about_item label="Role" value={role_label(@current_scope.user.role)} />
              <.about_item label="Company" value={@organization.company_name} />
              <.about_item label="GSTIN" value={@organization.gstin} />
              <.about_item label="Location" value={@location} />
            </dl>

            <p
              :if={
                !present?(@current_scope.user.full_name) or !present?(@current_scope.user.designation)
              }
              class="mt-4 rounded-field bg-base-200 px-3 py-2 text-xs text-base-content/60"
            >
              Your profile is incomplete.
              <.link navigate={~p"/users/settings"} class="font-medium text-base-content underline">
                Add your name and designation
              </.link>
            </p>
          </.card>

          <.card id="profile-activity" padding="p-4">
            <h2 class="text-sm font-semibold tracking-tight">Recent activity</h2>

            <.empty_state
              :if={@activity == []}
              icon="hero-clock"
              title="No activity yet"
              description="Invoices, e-way bills and payments you work on will show up here."
            />

            <ol :if={@activity != []} class="mt-3 space-y-1">
              <li
                :for={log <- @activity}
                id={"activity-#{log.id}"}
                class="flex items-center gap-3 rounded-field px-2 py-2 transition-colors hover:bg-base-200/60"
              >
                <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-base-200 text-base-content/60">
                  <.icon name={activity_icon(log.resource_type)} class="size-4" />
                </span>
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-medium">{humanize(log.action)}</span>
                  <span class="block truncate text-xs text-base-content/50">
                    {resource_label(log.resource_type)}<span :if={present?(log.resource_id)}> · {log.resource_id}</span>
                  </span>
                </span>
                <time class="shrink-0 text-xs text-base-content/45" title={to_string(log.inserted_at)}>
                  {relative_time(log.inserted_at)}
                </time>
              </li>
            </ol>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil

  defp contact_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-base-200 text-base-content/60">
        <.icon name={@icon} class="size-4" />
      </span>
      <span class="min-w-0">
        <span class="block text-xs text-base-content/45">{@label}</span>
        <span
          class={["block truncate text-sm", !present?(@value) && "text-base-content/40"]}
          title={@value}
        >
          {if present?(@value), do: @value, else: "Not added"}
        </span>
      </span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil

  defp about_item(assigns) do
    ~H"""
    <div>
      <dt class="text-xs text-base-content/45">{@label}</dt>
      <dd class={["mt-0.5 truncate", !present?(@value) && "text-base-content/40"]}>
        {if present?(@value), do: @value, else: "—"}
      </dd>
    </div>
    """
  end

  defp banner_seed(%{banner_seed: seed}) when is_integer(seed), do: seed
  defp banner_seed(%{id: id}), do: id

  defp location(organization) do
    [organization.city, organization.state]
    |> Enum.filter(&present?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp display_name(user) do
    Enum.find([user.full_name, user.username, user.email], &present?/1)
  end

  defp role_label("owner"), do: "Owner"
  defp role_label(_role), do: "Staff"

  defp activity_icon("Invoice"), do: "hero-document-text"
  defp activity_icon("EWayBill"), do: "hero-truck"
  defp activity_icon("Client"), do: "hero-user-group"
  defp activity_icon("InvoiceTemplate"), do: "hero-swatch"
  defp activity_icon("RecurringProfile"), do: "hero-arrow-path"
  defp activity_icon(_type), do: "hero-bolt"

  defp resource_label("EWayBill"), do: "E-way bill"
  defp resource_label("InvoiceTemplate"), do: "Invoice template"
  defp resource_label("RecurringProfile"), do: "Recurring profile"
  defp resource_label(type), do: humanize(type)

  defp humanize(nil), do: ""

  defp humanize(value) do
    value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp initials(%{full_name: name}) when is_binary(name) and name != "" do
    case String.split(name, ~r/\s+/, trim: true) do
      [single] -> single |> String.slice(0, 2) |> String.upcase()
      [first, second | _] -> String.upcase(String.first(first) <> String.first(second))
      [] -> "--"
    end
  end

  defp initials(%{email: email}) when is_binary(email) do
    email |> String.slice(0, 2) |> String.upcase()
  end

  defp initials(_user), do: "--"
end
