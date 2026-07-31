defmodule QuantumBillingWeb.SettingsComponents do
  @moduledoc """
  Building blocks for the Settings page: the section nav down the left, the
  panel header carrying each section's Save action, and the labelled toggle used
  by the boolean settings.

  The labelled `field/1` these panels use lives in
  `QuantumBillingWeb.SharedComponents` and is auto-imported.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]
  import QuantumBillingWeb.SharedComponents, only: [card: 1, action_button_class: 0]

  use QuantumBillingWeb, :verified_routes

  @sections [
    %{
      key: :general,
      title: "General Settings",
      subtitle: "Company details and basic settings",
      icon: "hero-cog-6-tooth"
    },
    %{
      key: :invoice,
      title: "Invoice Settings",
      subtitle: "Invoice numbering and preferences",
      icon: "hero-document-text"
    },
    %{
      key: :e_way_bill,
      title: "E-Way Bill Settings",
      subtitle: "E-way bill and transport settings",
      icon: "hero-truck"
    },
    %{
      key: :tax,
      title: "Tax Settings",
      subtitle: "GST rates and tax configurations",
      icon: "hero-receipt-percent"
    },
    %{
      key: :users,
      title: "Users & Roles",
      subtitle: "Manage users and roles",
      icon: "hero-users"
    },
    %{
      key: :notifications,
      title: "Notifications",
      subtitle: "Email and in-app notifications",
      icon: "hero-bell"
    },
    %{
      key: :backup,
      title: "Backup & Restore",
      subtitle: "Backup your data and restore",
      icon: "hero-cloud-arrow-up"
    },
    %{
      key: :integrations,
      title: "Integrations",
      subtitle: "Third party integrations",
      icon: "hero-squares-2x2"
    },
    %{
      key: :security,
      title: "Security",
      subtitle: "Password and security settings",
      icon: "hero-lock-closed"
    },
    %{
      key: :preferences,
      title: "Preferences",
      subtitle: "Language and theme settings",
      icon: "hero-computer-desktop"
    }
  ]

  @doc "Every section, in the order the nav shows them."
  def sections, do: @sections

  @doc "The section for `key`, or the general section when it is unknown."
  def section(key) do
    Enum.find(@sections, hd(@sections), &(&1.key == key))
  end

  @doc """
  Renders the left-hand section nav.

  Each entry links to its own URL so a section can be bookmarked and survives a
  reload. The active treatment matches the app sidebar rather than the
  screenshot's blue highlight.
  """
  attr :active, :atom, required: true

  def section_nav(assigns) do
    assigns = assign(assigns, :sections, @sections)

    ~H"""
    <.card padding="p-2">
      <nav class="space-y-0.5">
        <.link
          :for={section <- @sections}
          patch={~p"/settings/#{section.key}"}
          class={[
            "flex items-start gap-3 rounded-field px-3 py-2.5 transition-colors",
            if(@active == section.key,
              do: "bg-base-200",
              else: "hover:bg-base-200/60"
            )
          ]}
        >
          <span class={[
            "mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-field",
            if(@active == section.key,
              do: "bg-base-100 text-base-content",
              else: "bg-base-200 text-base-content/60"
            )
          ]}>
            <.icon name={section.icon} class="size-4" />
          </span>

          <span class="min-w-0">
            <span class={[
              "block text-sm",
              if(@active == section.key,
                do: "font-medium text-base-content",
                else: "text-base-content/80"
              )
            ]}>
              {section.title}
            </span>
            <span class="block text-xs text-base-content/45">{section.subtitle}</span>
          </span>
        </.link>
      </nav>
    </.card>
    """
  end

  @doc """
  Renders a panel's title row, with an optional Save button wired to `form`.
  """
  attr :title, :string, required: true
  attr :form_id, :string, default: nil

  def panel_header(assigns) do
    ~H"""
    <div class="mb-5 flex items-center justify-between gap-4">
      <h2 class="text-base font-semibold tracking-tight">{@title}</h2>

      <button :if={@form_id} type="submit" form={@form_id} class={action_button_class()}>
        <.icon name="hero-check" class="size-4" /> Save Changes
      </button>
    </div>
    """
  end

  @doc """
  Renders a labelled on/off row for a boolean setting.

  A checkbox rather than a switch: `CoreComponents.input/1` renders the hidden
  false value that a form needs to turn a setting *off*, which a hand-rolled
  toggle would have to reimplement.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  def toggle(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-start gap-3 rounded-field border border-base-300 px-3.5 py-3 transition-colors hover:bg-base-200/60">
      <input type="hidden" name={@field.name} value="false" />
      <input
        type="checkbox"
        id={@field.id}
        name={@field.name}
        value="true"
        checked={to_string(@field.value) in ["true", "1"]}
        class="mt-0.5 size-4 shrink-0 accent-base-content"
      />
      <span class="min-w-0">
        <span class="block text-sm">{@label}</span>
        <span :if={@hint} class="mt-0.5 block text-xs text-base-content/45">{@hint}</span>
      </span>
    </label>
    """
  end

  @doc """
  Renders a panel for something that genuinely is not built yet.

  Says what the section needs rather than implying it is merely unfinished, so
  nobody goes looking for a button that cannot exist.
  """
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :needs, :string, required: true

  def unbuilt_panel(assigns) do
    ~H"""
    <div class="flex flex-col items-center px-6 py-14 text-center">
      <span class="mb-3 flex size-10 items-center justify-center rounded-full bg-base-200 text-base-content/45">
        <.icon name={@icon} class="size-4.5" />
      </span>
      <p class="text-sm font-medium">{@title} is not available yet</p>
      <p class="mt-1 max-w-sm text-sm text-base-content/60">{@needs}</p>
    </div>
    """
  end
end
