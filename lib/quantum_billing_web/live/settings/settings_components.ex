defmodule QuantumBillingWeb.SettingsComponents do
  @moduledoc """
  The Settings section list and the boolean toggle row.

  `sections/0` is shared with the app sidebar, so it lives here.
  """
  use Phoenix.Component

  # `short_title` fits the sidebar; icons are distinct so they read alone.
  @sections [
    %{
      key: :company,
      title: "Company Profile",
      short_title: "Company Profile",
      subtitle: "Your company at a glance",
      icon: "hero-identification"
    },
    %{
      key: :general,
      title: "General Settings",
      short_title: "General",
      subtitle: "Company details and basic settings",
      icon: "hero-building-office"
    },
    %{
      key: :invoice,
      title: "Invoice Settings",
      short_title: "Invoice",
      subtitle: "Invoice numbering and preferences",
      icon: "hero-document-text"
    },
    %{
      key: :e_way_bill,
      title: "E-Way Bill Settings",
      short_title: "E-Way Bill",
      subtitle: "E-way bill and transport settings",
      icon: "hero-truck"
    },
    %{
      key: :tax,
      title: "Tax Settings",
      short_title: "Tax",
      subtitle: "GST rates and tax configurations",
      icon: "hero-receipt-percent"
    },
    %{
      key: :customization,
      title: "Invoice Customization",
      short_title: "Customization",
      subtitle: "Logo, colours and what appears on your invoices",
      icon: "hero-paint-brush"
    },
    %{
      key: :notifications,
      title: "Notifications",
      short_title: "Notifications",
      subtitle: "Email and in-app notifications",
      icon: "hero-bell"
    },
    %{
      key: :smtp,
      title: "SMTP Server Configuration",
      short_title: "SMTP Server",
      subtitle: "Configure custom SMTP mail server for sending invoices",
      icon: "hero-server-stack"
    },
    %{
      key: :backup,
      title: "Backup & Restore",
      short_title: "Backup & Restore",
      subtitle: "Backup your data and restore database",
      icon: "hero-cloud-arrow-up"
    },
    %{
      key: :integrations,
      title: "Integrations",
      short_title: "Integrations",
      subtitle: "API, Razorpay & E-Invoice credentials",
      icon: "hero-puzzle-piece"
    },
    %{
      key: :security,
      title: "Security & Access",
      short_title: "Security",
      subtitle: "IP Whitelisting, session timeout & security policies",
      icon: "hero-lock-closed"
    },
    %{
      key: :preferences,
      title: "Preferences",
      short_title: "Preferences",
      subtitle: "Language and theme settings",
      icon: "hero-adjustments-horizontal"
    }
  ]

  @doc "Every section, in the order the nav shows them."
  def sections, do: @sections

  @doc "The section for `key`, or the first (Company Profile) when it is unknown."
  def section(key) do
    Enum.find(@sections, hd(@sections), &(&1.key == key))
  end

  @doc """
  A labelled checkbox row for a boolean setting. The hidden `false` input lets it turn off.
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
end
