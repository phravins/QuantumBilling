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
  import QuantumBillingWeb.Format, only: [rupees: 2, format_date: 1, rupees_in_words: 1]
  import QuantumBillingWeb.SharedComponents, only: [brand_mark: 1]

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

  Driven by `InvoiceDocument.config/1` and `InvoiceDocument.sample/0` — the same
  resolver the real document uses — so a toggle that does nothing here does
  nothing there either. It is scaled down rather than simplified: hiding detail
  would let the preview agree with settings it is not actually honouring.
  """
  attr :settings, :map, required: true, doc: "the Organization being edited, saved or not"
  attr :organization, :map, required: true, doc: "the saved row, for the stored logo path"

  def invoice_preview(assigns) do
    config = InvoiceDocument.config(assigns.settings)
    invoice = InvoiceDocument.sample()

    assigns =
      assigns
      |> assign(:config, config)
      |> assign(:invoice, invoice)
      |> assign(:logo, config.logo || assigns.organization.doc_logo_path)
      |> assign(:show_cess?, InvoiceDocument.show_cess?(config, invoice))
      |> assign(:heading, InvoiceDocument.heading(config, invoice))

    ~H"""
    <div class="overflow-hidden rounded-box border border-base-300 bg-base-100 p-5 text-2xs shadow-sm">
      <div class="flex items-start justify-between gap-4">
        <div>
          <img :if={@logo} src={@logo} alt="" class="mb-2 max-h-8 max-w-32" />
          <.brand_mark
            :if={is_nil(@logo)}
            class="mb-2"
            icon_class="size-5"
            label_class="text-xs font-semibold"
          />
          <p class="font-semibold">{@invoice.company_name}</p>
          <p class="whitespace-pre-line text-base-content/60">{@invoice.company_address}</p>
        </div>

        <div class="text-right">
          <p class="text-sm font-semibold" style={"color: #{@config.accent}"}>{@heading}</p>
          <p class="font-medium">{@invoice.invoice_number}</p>
          <p class="text-base-content/60">{format_date(@invoice.invoice_date)}</p>
        </div>
      </div>

      <p class="mt-3 uppercase tracking-wider text-base-content/45">Bill To</p>
      <p class="font-semibold">{@invoice.client_name}</p>

      <table class="mt-3 w-full">
        <thead>
          <tr
            class="border-b uppercase tracking-wider text-base-content/45"
            style={"border-color: #{@config.accent}"}
          >
            <th class="py-1 pr-2 text-left font-semibold">#</th>
            <th class="py-1 pr-2 text-left font-semibold">Item</th>
            <th :if={@config.show_hsn} class="py-1 pr-2 text-left font-semibold">HSN</th>
            <th class="py-1 pr-2 text-right font-semibold">Qty</th>
            <th :if={@config.show_unit} class="py-1 pr-2 text-left font-semibold">Unit</th>
            <th class="py-1 pr-2 text-right font-semibold">Rate</th>
            <th :if={@config.show_tax_rate} class="py-1 pr-2 text-right font-semibold">Tax %</th>
            <th class="py-1 text-right font-semibold">Amount</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={{item, index} <- Enum.with_index(@invoice.items, 1)}
            class="border-b border-base-200"
          >
            <td class="py-1 pr-2 text-base-content/45">{index}</td>
            <td class="py-1 pr-2">{item.description}</td>
            <td :if={@config.show_hsn} class="py-1 pr-2 text-base-content/60">{item.hsn_sac}</td>
            <td class="py-1 pr-2 text-right">{item.quantity}</td>
            <td :if={@config.show_unit} class="py-1 pr-2 text-base-content/60">{item.unit}</td>
            <td class="py-1 pr-2 text-right">{rupees(item.rate, decimals: 2)}</td>
            <td :if={@config.show_tax_rate} class="py-1 pr-2 text-right text-base-content/60">
              {item.tax_rate}%
            </td>
            <td class="py-1 text-right font-medium">{rupees(item.amount, decimals: 2)}</td>
          </tr>
        </tbody>
      </table>

      <div class="ml-auto mt-3 w-48 space-y-1">
        <.preview_total label="Taxable Value" value={rupees(@invoice.taxable_value, decimals: 2)} />
        <.preview_total label="CGST" value={rupees(@invoice.cgst_amount, decimals: 2)} />
        <.preview_total label="SGST" value={rupees(@invoice.sgst_amount, decimals: 2)} />
        <.preview_total
          :if={@show_cess?}
          label="Cess"
          value={rupees(@invoice.cess_amount, decimals: 2)}
        />
        <div
          class="flex justify-between border-t pt-1 text-xs font-semibold"
          style={"border-color: #{@config.accent}; color: #{@config.accent}"}
        >
          <span>Grand Total</span>
          <span>{rupees(@invoice.grand_total, decimals: 2)}</span>
        </div>
      </div>

      <div :if={@config.show_amount_words} class="mt-3">
        <p class="uppercase tracking-wider text-base-content/45">Amount in Words</p>
        <p class="text-base-content/60">{rupees_in_words(@invoice.grand_total)}</p>
      </div>

      <div :if={@config.show_remarks and @invoice.remarks} class="mt-3">
        <p class="uppercase tracking-wider text-base-content/45">Remarks</p>
        <p class="text-base-content/60">{@invoice.remarks}</p>
      </div>

      <p
        :if={@config.footer}
        class="mt-4 border-t border-base-200 pt-2 text-center text-base-content/45"
      >
        {@config.footer}
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp preview_total(assigns) do
    ~H"""
    <div class="flex justify-between">
      <span class="text-base-content/60">{@label}</span>
      <span>{@value}</span>
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
