defmodule QuantumBillingWeb.PublicQuotationLive do
  @moduledoc """
  The client's page for a quotation, reached from the emailed link: the
  quotation as a document, a PDF download, and Accept or Decline while it is
  open. No account is needed; the token in the link is the access control.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Businesses
  alias QuantumBilling.Quotations
  alias QuantumBilling.Quotations.Quotation
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Extras
  alias QuantumBillingWeb.InvoiceDoc.QuotationLayout
  alias QuantumBillingWeb.InvoiceDoc.Renderer
  alias QuantumBillingWeb.InvoicePdfGenerator

  # Recorded on the audit row of a client's answer.
  @actor [via: "public link"]

  @doc """
  The client's link for `token`, named with the current business's slug so
  the page knows whose books to open.
  """
  def path(token), do: ~p"/q/#{QuantumBilling.Repo.business().slug}/#{token}"

  def mount(%{"token" => token} = params, _session, socket) do
    # Visitors have no session business: the link names it. Set for the life
    # of this LiveView process, so the client's answer is written there too.
    business = Businesses.from_link(params["slug"])
    QuantumBilling.Repo.put_business(business)

    case business && Quotations.get_quotation_by_token(token) do
      nil ->
        {:ok, gone(socket)}

      quotation ->
        {:ok,
         socket
         |> assign(:page_title, "Quotation #{quotation.number}")
         |> assign(:business, business)
         |> assign(:token, token)
         |> assign(:answer_error, nil)
         |> assign_quotation(quotation)}
    end
  end

  def handle_event("accept", _params, socket), do: answer(socket, &Quotations.accept/2)
  def handle_event("decline", _params, socket), do: answer(socket, &Quotations.decline/2)

  # Re-read by the token: the quotation may have been binned, answered or
  # extended since the page opened.
  defp answer(socket, action) do
    case Quotations.get_quotation_by_token(socket.assigns.token) do
      nil ->
        {:noreply, gone(socket)}

      quotation ->
        case action.(@actor, quotation) do
          {:ok, updated} ->
            {:noreply, socket |> assign(:answer_error, nil) |> assign_quotation(updated)}

          {:error, _reason} ->
            current = Quotations.get_quotation_by_token(socket.assigns.token) || quotation

            {:noreply,
             socket
             |> assign(
               :answer_error,
               "This quotation can no longer be answered here. Please contact the business that sent it."
             )
             |> assign_quotation(current)}
        end
    end
  end

  defp assign_quotation(socket, %Quotation{} = quotation) do
    document = Quotations.as_document(quotation)
    {doc, accent, logo} = Templates.document_for(document)
    doc = QuotationLayout.adapt(doc)

    socket
    |> assign(:quotation, quotation)
    |> assign(:status, Quotation.effective_status(quotation, Quotations.today()))
    |> assign(:document, document)
    |> assign(:doc, doc)
    |> assign(:accent, accent)
    # A visitor has no session, so /uploads refuses them.
    |> assign(:logo, InvoicePdfGenerator.inline_logo(logo))
    |> assign(:extras, Extras.build(document, doc, inline: true))
  end

  defp gone(socket) do
    socket
    |> put_flash(:error, "Invalid or expired quotation link.")
    |> push_navigate(to: "/")
  end

  defp open?(status), do: status in ["Draft", "Sent"]

  def render(assigns) do
    ~H"""
    <Layouts.skip_link />
    <main
      id="main-content"
      tabindex="-1"
      class="min-h-screen bg-base-200/50 py-8 px-4 focus:outline-none sm:px-6 lg:px-8"
    >
      <div class="max-w-4xl mx-auto space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 bg-base-100 p-6 rounded-2xl border border-base-300 shadow-sm">
          <div>
            <span class="text-xs font-bold uppercase tracking-wider text-base-content/50">
              Quotation from {@quotation.company_name}
            </span>
            <h1 class="text-xl font-bold tracking-tight text-base-content">
              Quotation {@quotation.number}
            </h1>
            <p class="text-xs text-base-content/60 mt-0.5">
              Dated {format_date(@quotation.quotation_date)} · Valid until {format_date(@quotation.valid_until)} · Total:
              <strong class="text-base-content">{money(@quotation.grand_total, @quotation.currency)}</strong>
            </p>
          </div>

          <p
            :if={@answer_error}
            id="public-quotation-error"
            role="alert"
            class="w-full rounded-lg border border-error/30 bg-error/10 px-3 py-2 text-xs text-error sm:order-last"
          >
            {@answer_error}
          </p>

          <div class="flex flex-wrap items-center gap-3">
            <span
              id="public-quotation-status"
              class={[
                "inline-flex items-center gap-1 rounded-field border px-2.5 py-1 text-xs font-semibold",
                @status == "Accepted" &&
                  "border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
                @status == "Declined" && "border-error/30 bg-error/10 text-error",
                @status == "Expired" && "border-warning/30 bg-warning/10 text-warning",
                open?(@status) && "border-base-300 text-base-content/70"
              ]}
            >
              <.icon
                name={
                  case @status do
                    "Accepted" -> "hero-check-circle"
                    "Declined" -> "hero-x-circle"
                    "Expired" -> "hero-clock"
                    _open -> "hero-document-text"
                  end
                }
                class="size-4"
              />
              {if open?(@status), do: "Awaiting your answer", else: @status}
            </span>

            <button
              :if={open?(@status)}
              id="public-decline-quotation"
              type="button"
              phx-click="decline"
              phx-disable-with="Declining…"
              data-confirm="Decline this quotation?"
              class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-xl border border-base-300 hover:border-error/40 hover:bg-error/5 hover:text-error text-xs font-semibold transition"
            >
              <.icon name="hero-x-mark" class="size-4" /> Decline
            </button>

            <button
              :if={open?(@status)}
              id="public-accept-quotation"
              type="button"
              phx-click="accept"
              phx-disable-with="Accepting…"
              data-confirm="Accept this quotation?"
              class="inline-flex items-center gap-2 px-5 py-2.5 rounded-xl bg-emerald-600 hover:bg-emerald-700 text-white font-bold text-sm shadow-md transition transform hover:-translate-y-0.5"
            >
              <.icon name="hero-check" class="size-4" /> Accept quotation
            </button>

            <.link
              id="public-quotation-pdf"
              href={~p"/q/#{@business.slug}/#{@token}/pdf"}
              target="_blank"
              class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-xl border border-base-300 hover:bg-base-200 text-xs font-semibold transition"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download PDF
            </.link>
          </div>
        </div>

        <div
          :if={@status == "Accepted"}
          id="public-quotation-accepted"
          class="p-4 rounded-xl bg-emerald-500/10 border border-emerald-500/30 text-xs text-emerald-700 dark:text-emerald-400 font-medium flex items-center gap-2"
        >
          <.icon name="hero-check-badge" class="size-5 shrink-0" />
          <span>Thank you. {@quotation.company_name} has your acceptance and will be in touch.</span>
        </div>

        <div
          :if={@status == "Expired"}
          id="public-quotation-expired"
          class="p-4 rounded-xl bg-warning/10 border border-warning/30 text-xs text-warning font-medium flex items-center gap-2"
        >
          <.icon name="hero-clock" class="size-5 shrink-0" />
          <span>This quotation passed its validity date. Please ask {@quotation.company_name} for a fresh one.</span>
        </div>

        <div class="bg-base-100 p-8 rounded-2xl border border-base-300 shadow-xl overflow-x-auto">
          <Renderer.stylesheet doc={@doc} />
          <Renderer.document
            doc={@doc}
            invoice={@document}
            accent={@accent}
            logo={@logo}
            extras={@extras}
          />
        </div>
      </div>
    </main>
    """
  end
end
