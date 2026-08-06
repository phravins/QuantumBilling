defmodule QuantumBillingWeb.InvoiceShowLive do
  @moduledoc """
  A saved invoice, rendered as the document it is.

  Serves two entry points: the Preview action on the create form, and the eye
  icon on the invoices list. Building it once for both is why it is a page
  rather than an inline preview.

  Everything shown here comes from the invoice's own columns, including the
  company and client blocks. Those were snapshotted at issue precisely so this
  page keeps showing what was billed even after the client or the organisation
  settings change.

  The document itself is not written here. It is rendered by
  `InvoiceDoc.Renderer` from a layout, which is the same markup and the same
  stylesheet the print page uses — the two used to be separate hand-written
  copies that a third module had to keep honest about each other.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoiceDoc.Renderer

  def mount(%{"id" => id}, _session, socket) do
    case Invoices.get_invoice(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That invoice does not exist.")
         |> push_navigate(to: ~p"/invoices")}

      invoice ->
        # The figures and party details come from the invoice's own snapshot;
        # only how it looks is read live, so rebranding restyles every invoice
        # instead of only the next one.
        organization = Settings.get_organization()

        {:ok,
         socket
         |> assign(:page_title, invoice.invoice_number)
         |> assign(:active_nav, :invoices)
         |> assign(:invoice, invoice)
         |> assign(:doc, Layout.from_legacy(organization))
         |> assign(:accent, organization.doc_accent_color || "#18181b")
         |> assign(:logo, presence(organization.doc_logo_path))}
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <nav class="mb-2 flex items-center gap-1.5 text-xs text-base-content/45" aria-label="Breadcrumb">
        <.link navigate={~p"/invoices"} class="hover:text-base-content">Invoices</.link>
        <.icon name="hero-chevron-right" class="size-3" />
        <span class="text-base-content/60">{@invoice.invoice_number}</span>
      </nav>

      <.header>
        {@invoice.invoice_number}
        <:subtitle>{@invoice.invoice_type}</:subtitle>
        <:actions>
          <div class="flex items-center gap-2">
            <.status_badge status={@invoice.status} />
            <.link navigate={~p"/invoices"} class={secondary_button_class()}>
              <.icon name="hero-arrow-left" class="size-4" /> Back to Invoices
            </.link>
          </div>
        </:actions>
      </.header>
      <.card padding="p-8">
        <Renderer.stylesheet doc={@doc} />
        <Renderer.document doc={@doc} invoice={@invoice} accent={@accent} logo={@logo} />
      </.card>
    </Layouts.app>
    """
  end
end
