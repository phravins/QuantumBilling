defmodule QuantumBillingWeb.SettingsComponents do
  @moduledoc """
  Building blocks for the Settings page: the labelled toggle used by the
  boolean settings, the invoice preview on the Customization panel, and the
  panel for a section that is not built yet.

  `sections/0` is the single source of truth for the section list. The app
  sidebar reads it too, which is why it lives here rather than in the LiveView.
  Each section's title is rendered by the page header, not in here.

  The labelled `field/1` these panels use lives in
  `QuantumBillingWeb.SharedComponents` and is auto-imported.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]

  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoiceDoc.Renderer
  alias QuantumBillingWeb.InvoiceDocument

  # `short_title` is what the sidebar shows. The sidebar is only 12rem wide and
  # already says "Settings" above these, so the suffix is both redundant and too
  # long to fit.
  @sections [
    %{
      key: :general,
      title: "General Settings",
      short_title: "General",
      subtitle: "Company details and basic settings",
      icon: "hero-cog-6-tooth"
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
      key: :backup,
      title: "Backup & Restore",
      short_title: "Backup & Restore",
      subtitle: "Backup your data and restore",
      icon: "hero-cloud-arrow-up"
    },
    %{
      key: :integrations,
      title: "Integrations",
      short_title: "Integrations",
      subtitle: "Third party integrations",
      icon: "hero-squares-2x2"
    },
    %{
      key: :security,
      title: "Security",
      short_title: "Security",
      subtitle: "Password and security settings",
      icon: "hero-lock-closed"
    },
    %{
      key: :preferences,
      title: "Preferences",
      short_title: "Preferences",
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
  Renders a miniature invoice reflecting the customization settings.

  Rendered by `InvoiceDoc.Renderer` from the layout the settings describe — the
  same component and the same stylesheet the real document uses — so a toggle
  that does nothing here does nothing there either. It is scaled down rather
  than simplified: hiding detail would let the preview agree with a setting it
  is not actually honouring.

  `settings` is the unsaved changeset draft, so the preview follows the form
  rather than the stored row.
  """
  attr :settings, :map, required: true, doc: "the Organization being edited, saved or not"
  attr :organization, :map, required: true, doc: "the saved row, for the stored logo path"

  def invoice_preview(assigns) do
    assigns =
      assigns
      |> assign(:doc, Layout.from_legacy(assigns.settings))
      |> assign(:invoice, InvoiceDocument.sample())
      |> assign(:accent, assigns.settings.doc_accent_color || "#18181b")
      |> assign(:logo, assigns.settings.doc_logo_path || assigns.organization.doc_logo_path)

    ~H"""
    <div class="overflow-hidden rounded-box border border-base-300 bg-base-100 p-3 shadow-sm">
      <Renderer.stylesheet doc={@doc} />
      <Renderer.thumbnail
        doc={@doc}
        invoice={@invoice}
        accent={@accent}
        logo={@logo}
        scale={0.42}
      />
    </div>
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
    <div class="flex flex-1 flex-col items-center justify-center px-6 py-14 text-center">
      <span class="mb-3 flex size-10 items-center justify-center rounded-full bg-base-200 text-base-content/45">
        <.icon name={@icon} class="size-4.5" />
      </span>
      <p class="text-sm font-medium">{@title} is not available yet</p>
      <p class="mt-1 max-w-sm text-sm text-base-content/60">{@needs}</p>
    </div>
    """
  end
end
