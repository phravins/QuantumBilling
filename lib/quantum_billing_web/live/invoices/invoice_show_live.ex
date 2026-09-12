defmodule QuantumBillingWeb.InvoiceShowLive do
  @moduledoc """
  A saved invoice, rendered as the document it is.

  Serves preview and management actions: 1-click IRN generation, PDF downloads,
  email notifications, and E-Invoice metadata display.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.InvoiceNotifier
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
        {doc, accent, logo} = Templates.document_for(invoice)

        {:ok,
         socket
         |> assign(:page_title, invoice.invoice_number)
         |> assign(:active_nav, :invoices)
         |> assign(:invoice, invoice)
         |> assign(:doc, doc)
         |> assign(:accent, accent)
         |> assign(:logo, logo)
         |> assign(:show_qr_modal, false)}
    end
  end

  def handle_event("generate_einvoice", _params, socket) do
    case Invoices.generate_einvoice(socket.assigns.invoice) do
      {:ok, updated_invoice} ->
        {doc, accent, logo} = Templates.document_for(updated_invoice)

        {:noreply,
         socket
         |> put_flash(:info, "E-Invoice (IRN) generated successfully!")
         |> assign(:invoice, updated_invoice)
         |> assign(:doc, doc)
         |> assign(:accent, accent)
         |> assign(:logo, logo)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate E-Invoice: #{reason}")}
    end
  end

  def handle_event("send_email", _params, socket) do
    invoice = socket.assigns.invoice
    recipient = invoice.client_email || "customer@example.com"

    case InvoiceNotifier.deliver_invoice_pdf(recipient, invoice) do
      {:ok, _email} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Invoice #{invoice.invoice_number} sent to #{recipient} with PDF attachment!"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not send email: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_qr_modal", _params, socket) do
    {:noreply, assign(socket, :show_qr_modal, !socket.assigns.show_qr_modal)}
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

            <button
              :if={@invoice.status != "E-Invoice Generated"}
              type="button"
              phx-click="generate_einvoice"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-semibold shadow-sm transition"
            >
              <.icon name="hero-bolt" class="size-4" /> 1-Click Generate IRN
            </button>

            <button
              type="button"
              phx-click="send_email"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-semibold shadow-sm transition"
            >
              <.icon name="hero-paper-airplane" class="size-4" /> Send PDF via Email
            </button>

            <.link
              href={~p"/invoices/#{@invoice.id}/pdf"}
              target="_blank"
              class={secondary_button_class()}
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> PDF
            </.link>

            <.link navigate={~p"/invoices"} class={secondary_button_class()}>
              <.icon name="hero-arrow-left" class="size-4" /> Back to Invoices
            </.link>
          </div>
        </:actions>
      </.header>

      <%!-- Official E-Invoice IRP Banner --%>
      <div
        :if={@invoice.irn}
        class="mb-6 rounded-xl border border-emerald-500/30 bg-emerald-500/10 p-4"
      >
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div class="space-y-1">
            <div class="flex items-center gap-2">
              <span class="inline-flex items-center gap-1 rounded-md bg-emerald-600 px-2 py-0.5 text-xs font-bold text-white">
                <.icon name="hero-check-badge" class="size-3.5" /> E-Invoice Verified (IRP)
              </span>
              <span class="text-xs text-base-content/60">
                Ack No: <strong class="text-base-content">{@invoice.ack_number}</strong>
              </span>
            </div>
            <p class="font-mono text-xs text-emerald-400 break-all">
              IRN: {@invoice.irn}
            </p>
          </div>

          <button
            :if={@invoice.signed_qr_code}
            type="button"
            phx-click="toggle_qr_modal"
            class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-emerald-500/40 text-xs font-medium hover:bg-emerald-500/20"
          >
            <.icon name="hero-qr-code" class="size-4" /> View Signed QR Code
          </button>
        </div>
      </div>

      <.card padding="p-8">
        <Renderer.stylesheet doc={@doc} />
        <Renderer.document doc={@doc} invoice={@invoice} accent={@accent} logo={@logo} />
      </.card>

      <%!-- Signed QR Modal --%>
      <div
        :if={@show_qr_modal}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      >
        <div class="w-full max-w-md rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl space-y-4">
          <div class="flex items-center justify-between border-b border-base-200 pb-3">
            <h3 class="text-base font-bold">Government E-Invoice QR Payload</h3>
            <button
              type="button"
              phx-click="toggle_qr_modal"
              class="text-base-content/50 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
          <div class="p-3 bg-base-200 rounded-lg text-xs font-mono break-all max-h-60 overflow-y-auto">
            {@invoice.signed_qr_code}
          </div>
          <button
            type="button"
            phx-click="toggle_qr_modal"
            class="w-full py-2 bg-base-200 hover:bg-base-300 rounded-lg text-xs font-semibold"
          >
            Close
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
