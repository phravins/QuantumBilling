defmodule QuantumBillingWeb.PublicInvoiceLive do
  @moduledoc """
  Publicly accessible LiveView page for clients to preview invoices, download PDFs,
  and pay online via Razorpay / UPI without creating an account.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Invoices
  alias QuantumBilling.Payments
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Renderer

  def mount(%{"token" => token}, _session, socket) do
    case Invoices.get_invoice_by_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid or expired invoice link.")
         |> push_navigate(to: "/")}

      invoice ->
        {doc, accent, logo} = Templates.document_for(invoice)

        if connected?(socket) do
          Invoices.subscribe()
        end

        {:ok,
         socket
         |> assign(:page_title, "Tax Invoice #{invoice.invoice_number}")
         |> assign(:invoice, invoice)
         |> assign(:doc, doc)
         |> assign(:accent, accent)
         |> assign(:logo, logo)}
    end
  end

  def handle_info({:invoice_changed, updated_invoice}, socket) do
    if updated_invoice.id == socket.assigns.invoice.id do
      {doc, accent, logo} = Templates.document_for(updated_invoice)

      {:noreply,
       socket
       |> assign(:invoice, updated_invoice)
       |> assign(:doc, doc)
       |> assign(:accent, accent)
       |> assign(:logo, logo)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  def handle_event("pay_now", _params, socket) do
    invoice = socket.assigns.invoice

    if invoice.razorpay_payment_url && invoice.razorpay_payment_url != "" do
      {:noreply, redirect(socket, external: invoice.razorpay_payment_url)}
    else
      case Payments.generate_payment_link(invoice) do
        {:ok, updated_invoice} ->
          {:noreply, redirect(socket, external: updated_invoice.razorpay_payment_url)}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not launch payment gateway: #{inspect(reason)}")}
      end
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200/50 py-8 px-4 sm:px-6 lg:px-8">
      <div class="max-w-4xl mx-auto space-y-6">
        <%!-- Header Navigation & Quick Actions --%>
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 bg-base-100 p-6 rounded-2xl border border-base-300 shadow-sm">
          <div>
            <span class="text-xs font-bold uppercase tracking-wider text-base-content/50">Client Invoice Portal</span>
            <h1 class="text-xl font-bold tracking-tight text-base-content">
              Tax Invoice {@invoice.invoice_number}
            </h1>
            <p class="text-xs text-base-content/60 mt-0.5">
              Issued on {@invoice.invoice_date} | Total Due:
              <strong class="text-emerald-600">₹{@invoice.grand_total}</strong>
            </p>
          </div>

          <div class="flex items-center gap-3">
            <span
              :if={@invoice.status == "Paid"}
              class="badge badge-success badge-lg text-xs font-bold gap-1"
            >
              <.icon name="hero-check-circle" class="size-4" /> PAID
            </span>

            <button
              :if={@invoice.status != "Paid"}
              type="button"
              phx-click="pay_now"
              class="inline-flex items-center gap-2 px-5 py-2.5 rounded-xl bg-emerald-600 hover:bg-emerald-700 text-white font-bold text-sm shadow-md transition transform hover:-translate-y-0.5"
            >
              <.icon name="hero-credit-card" class="size-4" /> Pay Now via UPI / Card
            </button>

            <.link
              href={~p"/invoices/#{@invoice.id}/pdf"}
              target="_blank"
              class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-xl border border-base-300 hover:bg-base-200 text-xs font-semibold"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download PDF
            </.link>
          </div>
        </div>

        <%!-- Status Alert Banner --%>
        <div
          :if={@invoice.status == "Paid"}
          class="p-4 rounded-xl bg-emerald-500/10 border border-emerald-500/30 text-xs text-emerald-600 font-medium flex items-center gap-2"
        >
          <.icon name="hero-check-badge" class="size-5 shrink-0" />
          <span>Payment of ₹{@invoice.grand_total} was successfully received. Transaction Ref:
          <strong class="font-mono">{@invoice.razorpay_payment_id || "Direct Receipt"}</strong></span>
        </div>

        <%!-- Main Invoice Document Render --%>
        <div class="bg-base-100 p-8 rounded-2xl border border-base-300 shadow-xl">
          <Renderer.stylesheet doc={@doc} />
          <Renderer.document doc={@doc} invoice={@invoice} accent={@accent} logo={@logo} />
        </div>

        <%!-- Footer Information --%>
        <div class="text-center text-xs text-base-content/45 py-4">
          Powered by
          <strong class="text-base-content/60">QuantumBilling Enterprise GST Engine</strong>
          &bull; Secure Encrypted Checkout
        </div>
      </div>
    </div>
    """
  end
end
