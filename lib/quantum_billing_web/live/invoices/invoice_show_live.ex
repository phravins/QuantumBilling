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
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Renderer

  def mount(%{"id" => id}, _session, socket) do
    case Invoices.get_invoice(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That invoice does not exist.")
         |> push_navigate(to: ~p"/invoices")}

      invoice ->
        # The figures and party details come from the invoice's own snapshot,
        # and so does the layout. Only the branding is read live, so recolouring
        # restyles every invoice instead of only the next one.
        {doc, accent, logo} = Templates.document_for(invoice)

        {:ok,
         socket
         |> assign(:page_title, invoice.invoice_number)
         |> assign(:active_nav, :invoices)
         |> assign(:invoice, invoice)
         |> assign(:doc, doc)
         |> assign(:accent, accent)
         |> assign(:logo, logo)}
    end
  end

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
          <div class="flex flex-wrap items-center gap-2">
            <.status_badge status={@invoice.status} />

            <%!-- Real navigations, not LiveView events: both hand the browser a
            file it has to load before it can offer to save it. --%>
            <.link
              href={~p"/invoices/#{@invoice.id}/pdf"}
              target="_blank"
              class={secondary_button_class()}
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> PDF
            </.link>

            <div class="flex items-center gap-1">
              <.link
                href={~p"/invoices/#{@invoice.id}/e-invoice.xml"}
                class={secondary_button_class()}
              >
                <.icon name="hero-code-bracket" class="size-4" /> E-Invoice XML
              </.link>

              <.help_popover id="e-invoice-help" label="About the e-invoice export">
                This is the invoice's data in the GST e-invoice (INV-01) schema, for your
                accountant, your GSP or your records. It is <strong>not</strong>
                a registered e-invoice: it carries no IRN and no signed QR code, because only
                the Invoice Registration Portal can issue those.
              </.help_popover>
            </div>

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
