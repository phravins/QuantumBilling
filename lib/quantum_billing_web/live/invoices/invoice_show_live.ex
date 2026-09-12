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

  def handle_event("generate_ewb", params, socket) do
    case QuantumBilling.EWayBills.generate_e_way_bill(socket.assigns.invoice, params) do
      {:ok, updated_invoice} ->
        {doc, accent, logo} = Templates.document_for(updated_invoice)

        {:noreply,
         socket
         |> put_flash(:info, "E-Way Bill #{updated_invoice.ewb_number} generated successfully!")
         |> assign(:invoice, updated_invoice)
         |> assign(:doc, doc)
         |> assign(:accent, accent)
         |> assign(:logo, logo)
         |> assign(:show_ewb_modal, false)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate E-Way Bill: #{inspect(reason)}")}
    end
  end

  def handle_event("generate_payment_link", _params, socket) do
    case QuantumBilling.Payments.generate_payment_link(socket.assigns.invoice) do
      {:ok, updated_invoice} ->
        {:noreply,
         socket
         |> put_flash(:info, "Razorpay / UPI Payment link generated successfully!")
         |> assign(:invoice, updated_invoice)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to generate Payment Link: #{inspect(reason)}")}
    end
  end

  def handle_event("issue_credit_note", params, socket) do
    case QuantumBilling.CreditNotes.create_credit_note_for_invoice(socket.assigns.invoice, params) do
      {:ok, cn} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{cn.note_type} Note #{cn.note_number} issued successfully!")
         |> assign(:show_cn_modal, false)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to issue Credit Note: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_qr_modal", _params, socket) do
    {:noreply, assign(socket, :show_qr_modal, !socket.assigns.show_qr_modal)}
  end

  def handle_event("toggle_ewb_modal", _params, socket) do
    {:noreply, assign(socket, :show_ewb_modal, !Map.get(socket.assigns, :show_ewb_modal, false))}
  end

  def handle_event("toggle_cn_modal", _params, socket) do
    {:noreply, assign(socket, :show_cn_modal, !Map.get(socket.assigns, :show_cn_modal, false))}
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
              :if={!@invoice.ewb_number}
              type="button"
              phx-click="toggle_ewb_modal"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-cyan-600 hover:bg-cyan-700 text-white text-xs font-semibold shadow-sm transition"
            >
              <.icon name="hero-truck" class="size-4" /> Generate E-Way Bill
            </button>

            <button
              :if={!@invoice.razorpay_payment_url}
              type="button"
              phx-click="generate_payment_link"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-xs font-semibold shadow-sm transition"
            >
              <.icon name="hero-qr-code" class="size-4" /> Razorpay / UPI Link
            </button>

            <button
              type="button"
              phx-click="toggle_cn_modal"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-amber-600 hover:bg-amber-700 text-white text-xs font-semibold shadow-sm transition"
            >
              <.icon name="hero-document-duplicate" class="size-4" /> Issue Credit/Debit Note
            </button>

            <.link
              href={~p"/pay/#{@invoice.public_token || "tok_123"}"}
              target="_blank"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-purple-600 hover:bg-purple-700 text-white text-xs font-semibold shadow-sm transition"
            >
              <.icon name="hero-globe-alt" class="size-4" /> Public Portal Link
            </.link>

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

      <%!-- Banners Section --%>
      <div class="mb-6 space-y-3">
        <%!-- Official E-Invoice IRP Banner --%>
        <div
          :if={@invoice.irn}
          class="rounded-xl border border-emerald-500/30 bg-emerald-500/10 p-4"
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

        <%!-- Official E-Way Bill Banner --%>
        <div
          :if={@invoice.ewb_number}
          class="rounded-xl border border-cyan-500/30 bg-cyan-500/10 p-4"
        >
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <span class="inline-flex items-center gap-1 rounded-md bg-cyan-600 px-2 py-0.5 text-xs font-bold text-white">
                  <.icon name="hero-truck" class="size-3.5" /> E-Way Bill Generated
                </span>
                <span class="text-xs text-base-content/60">
                  Vehicle:
                  <strong class="text-base-content">{@invoice.vehicle_number || "MH12AB1234"}</strong>
                  | Distance:
                  <strong class="text-base-content">{@invoice.distance_km || 250} km</strong>
                </span>
              </div>
              <p class="font-mono text-xs text-cyan-400 break-all">
                EWB No: {@invoice.ewb_number}
              </p>
            </div>
          </div>
        </div>

        <%!-- Razorpay Payment Link Card --%>
        <div
          :if={@invoice.razorpay_payment_url}
          class="rounded-xl border border-blue-500/30 bg-blue-500/10 p-4 flex flex-col sm:flex-row sm:items-center justify-between gap-4"
        >
          <div class="space-y-1">
            <div class="flex items-center gap-2">
              <span class="inline-flex items-center gap-1 rounded-md bg-blue-600 px-2 py-0.5 text-xs font-bold text-white">
                <.icon name="hero-qr-code" class="size-3.5" /> UPI & Card Payment Active
              </span>
              <span :if={@invoice.status == "Paid"} class="badge badge-success text-xs">
                Payment Received ({# {@invoice.razorpay_payment_id}})
              </span>
            </div>
            <p class="text-xs text-base-content/70">
              Payment URL:
              <a
                href={@invoice.razorpay_payment_url}
                target="_blank"
                class="text-blue-400 underline font-mono"
              >{@invoice.razorpay_payment_url}</a>
            </p>
          </div>
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

      <%!-- E-Way Bill Generation Modal --%>
      <div
        :if={Map.get(assigns, :show_ewb_modal, false)}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      >
        <div class="w-full max-w-md rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl space-y-4">
          <div class="flex items-center justify-between border-b border-base-200 pb-3">
            <h3 class="text-base font-bold">Generate Government E-Way Bill</h3>
            <button
              type="button"
              phx-click="toggle_ewb_modal"
              class="text-base-content/50 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
          <form phx-submit="generate_ewb" class="space-y-3">
            <div>
              <label class="block text-xs font-semibold mb-1">Distance (in KM)</label>
              <input
                type="number"
                name="distance_km"
                value="250"
                class="input input-bordered w-full text-xs"
                required
              />
            </div>
            <div>
              <label class="block text-xs font-semibold mb-1">Vehicle Number</label>
              <input
                type="text"
                name="vehicle_number"
                value="MH12AB1234"
                class="input input-bordered w-full text-xs"
                required
              />
            </div>
            <div>
              <label class="block text-xs font-semibold mb-1">Transporter ID (GSTIN)</label>
              <input
                type="text"
                name="transporter_id"
                value="27AAACG1234A1ZP"
                class="input input-bordered w-full text-xs"
              />
            </div>
            <div>
              <label class="block text-xs font-semibold mb-1">Mode of Transport</label>
              <select name="mode_of_transport" class="select select-bordered w-full text-xs">
                <option value="Road">Road</option>
                <option value="Rail">Rail</option>
                <option value="Air">Air</option>
                <option value="Ship">Ship</option>
              </select>
            </div>
            <div class="flex justify-end gap-2 pt-3 border-t border-base-200">
              <button type="button" phx-click="toggle_ewb_modal" class="btn btn-sm btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-sm btn-primary">Generate EWB</button>
            </div>
          </form>
        </div>
      </div>

      <%!-- Credit / Debit Note Modal --%>
      <div
        :if={Map.get(assigns, :show_cn_modal, false)}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      >
        <div class="w-full max-w-md rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl space-y-4">
          <div class="flex items-center justify-between border-b border-base-200 pb-3">
            <h3 class="text-base font-bold">Issue Credit / Debit Note</h3>
            <button
              type="button"
              phx-click="toggle_cn_modal"
              class="text-base-content/50 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
          <form phx-submit="issue_credit_note" class="space-y-3">
            <div>
              <label class="block text-xs font-semibold mb-1">Note Type</label>
              <select name="note_type" class="select select-bordered w-full text-xs">
                <option value="Credit">Credit Note (CN)</option>
                <option value="Debit">Debit Note (DN)</option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-semibold mb-1">Reason for Issue</label>
              <input
                type="text"
                name="reason"
                placeholder="e.g. Price adjustment, discount, goods returned"
                class="input input-bordered w-full text-xs"
                required
              />
            </div>
            <div>
              <label class="block text-xs font-semibold mb-1">Grand Total Amount (₹)</label>
              <input
                type="number"
                name="grand_total"
                value={@invoice.grand_total}
                class="input input-bordered w-full text-xs"
                required
              />
            </div>
            <div class="flex justify-end gap-2 pt-3 border-t border-base-200">
              <button type="button" phx-click="toggle_cn_modal" class="btn btn-sm btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-sm btn-warning">Issue Note</button>
            </div>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
