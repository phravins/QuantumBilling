defmodule QuantumBillingWeb.PublicInvoiceLive do
  @moduledoc """
  Publicly accessible LiveView page for clients to preview invoices, download PDFs,
  and pay online via Razorpay / UPI without creating an account.
  """
  use QuantumBillingWeb, :live_view

  require Logger

  alias QuantumBilling.Businesses
  alias QuantumBilling.Invoices
  alias QuantumBilling.Payments
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Renderer

  @doc """
  The customer's link to `invoice`. Named with the current business's slug, so
  the page knows whose books to open.
  """
  def path(invoice) do
    ~p"/p/#{QuantumBilling.Repo.business().slug}/#{invoice.public_token || "tok_123"}"
  end

  def mount(%{"token" => token} = params, _session, socket) do
    # Visitors have no session business: the link names it. Set for the life
    # of this LiveView process, so payment events and updates use it too.
    business = Businesses.from_link(params["slug"])
    QuantumBilling.Repo.put_business(business)

    case business && Invoices.get_invoice_by_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid or expired invoice link.")
         |> push_navigate(to: "/")}

      invoice ->
        {doc, accent, logo} = Templates.document_for(invoice)

        if connected?(socket) do
          # This invoice only. The global topic put every invoice in the
          # business through this unauthenticated process.
          Invoices.subscribe(invoice.id)
        end

        {:ok,
         socket
         |> assign(:page_title, "Tax Invoice #{invoice.invoice_number}")
         |> assign(:payment_error, nil)
         |> assign(:invoice, invoice)
         |> assign(:business, business)
         |> assign(:doc, doc)
         |> assign(:accent, accent)
         |> assign(:logo, logo)}
    end
  end

  # A broadcast is taken as "this invoice changed", never as the data to show.
  # The page re-reads through the same lookup the link itself uses, so it
  # renders exactly what a fresh visit would: a binned invoice is gone, and the
  # payload's shape — whether its line items happen to be loaded — cannot crash
  # a customer's page. It also means nothing that arrived in a message is ever
  # put on this unauthenticated screen.
  #
  # The id is still compared, although the per-invoice subscription makes a
  # mismatch impossible: a guarantee that holds only while two separate places
  # agree is not one to lean on with other customers' invoices.
  def handle_info({:invoice_changed, %{id: id}}, socket) when id == socket.assigns.invoice.id do
    {:noreply, reload(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  def handle_event("pay_now", _params, socket) do
    # Re-read through the same lookup the link itself uses rather than trusting
    # what was loaded when the page opened: the invoice may have been binned,
    # or paid from another tab, since.
    case Invoices.get_invoice_by_token(socket.assigns.invoice.public_token) do
      nil ->
        {:noreply, invoice_gone(socket)}

      %{razorpay_payment_url: url} when is_binary(url) and url != "" ->
        {:noreply, redirect(socket, external: url)}

      invoice ->
        case Payments.generate_payment_link(invoice) do
          {:ok, updated_invoice} ->
            {:noreply, redirect(socket, external: updated_invoice.razorpay_payment_url)}

          {:error, reason} ->
            # The customer gets a sentence; the business gets the reason. This
            # used to flash `inspect(reason)` to an unauthenticated visitor —
            # a gateway error body describing how payments are configured, or
            # a changeset carrying the invoice's own fields.
            Logger.error(
              "[PublicInvoice] payment link failed for invoice #{invoice.id}: #{inspect(reason)}"
            )

            # Inline rather than as a flash: this page has no layout, so a
            # flash is never rendered — a failed payment used to look like a
            # button that did nothing.
            {:noreply,
             assign(
               socket,
               :payment_error,
               "Online payment is not available right now. Please try again later, " <>
                 "or contact the business that sent this invoice."
             )}
        end
    end
  end

  defp reload(socket) do
    case Invoices.get_invoice_by_token(socket.assigns.invoice.public_token) do
      nil ->
        invoice_gone(socket)

      invoice ->
        {doc, accent, logo} = Templates.document_for(invoice)

        socket
        |> assign(:invoice, invoice)
        |> assign(:doc, doc)
        |> assign(:accent, accent)
        |> assign(:logo, logo)
    end
  end

  defp invoice_gone(socket) do
    socket
    |> put_flash(:error, "Invalid or expired invoice link.")
    |> push_navigate(to: "/")
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200/50 py-8 px-4 sm:px-6 lg:px-8">
      <div class="max-w-4xl mx-auto space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 bg-base-100 p-6 rounded-2xl border border-base-300 shadow-sm">
          <div>
            <span class="text-xs font-bold uppercase tracking-wider text-base-content/50">Client Invoice Portal</span>
            <h1 class="text-xl font-bold tracking-tight text-base-content">
              Tax Invoice {@invoice.invoice_number}
            </h1>
            <p class="text-xs text-base-content/60 mt-0.5">
              Issued on {@invoice.invoice_date} | Total Due:
              <strong class="text-emerald-600">{rupees(@invoice.grand_total)}</strong>
            </p>
          </div>

          <p
            :if={@payment_error}
            id="payment-error"
            role="alert"
            class="w-full rounded-lg border border-error/30 bg-error/10 px-3 py-2 text-xs text-error sm:order-last"
          >
            {@payment_error}
          </p>

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
              href={~p"/p/#{@business.slug}/#{@invoice.public_token}/pdf"}
              target="_blank"
              class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-xl border border-base-300 hover:bg-base-200 text-xs font-semibold"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download PDF
            </.link>
          </div>
        </div>

        <div
          :if={@invoice.status == "Paid"}
          class="p-4 rounded-xl bg-emerald-500/10 border border-emerald-500/30 text-xs text-emerald-600 font-medium flex items-center gap-2"
        >
          <.icon name="hero-check-badge" class="size-5 shrink-0" />
          <span>Payment of {rupees(@invoice.grand_total)} was successfully received. Transaction Ref:
          <strong class="font-mono">{@invoice.razorpay_payment_id || "Direct Receipt"}</strong></span>
        </div>

        <div
          :if={@invoice.status != "Paid"}
          class="bg-base-100 p-6 rounded-2xl border border-emerald-500/30 shadow-md flex flex-col sm:flex-row items-center justify-between gap-6"
        >
          <div class="space-y-2 flex-1 text-center sm:text-left">
            <div class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md bg-emerald-500/10 text-emerald-600 font-bold text-xs">
              <.icon name="hero-qr-code" class="size-4" /> Instant UPI Payment
            </div>
            <h2 class="text-lg font-bold text-base-content">
              Scan & Pay {rupees(@invoice.grand_total)}
            </h2>
            <p class="text-xs text-base-content/70">
              Open Google Pay, PhonePe, Paytm, BHIM, or any banking app on your phone and scan this QR code to complete payment instantly.
            </p>
            <div class="pt-2 flex flex-wrap items-center justify-center sm:justify-start gap-2">
              <button
                type="button"
                phx-click="pay_now"
                class="inline-flex items-center gap-1.5 px-4 py-2 rounded-xl bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold shadow transition"
              >
                <.icon name="hero-credit-card" class="size-4" /> Pay via Card / NetBanking
              </button>
            </div>
          </div>

          <div class="shrink-0 flex flex-col items-center justify-center bg-white p-3 rounded-2xl border border-base-300 shadow-sm">
            <.upi_qr
              invoice={@invoice}
              size_class="w-40 h-40"
              caption="Scan with any UPI App"
              caption_class="mt-2 text-2xs font-mono font-semibold text-gray-600"
            />
          </div>
        </div>

        <div class="bg-base-100 p-8 rounded-2xl border border-base-300 shadow-xl">
          <Renderer.stylesheet doc={@doc} />
          <Renderer.document doc={@doc} invoice={@invoice} accent={@accent} logo={@logo} />
        </div>

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
