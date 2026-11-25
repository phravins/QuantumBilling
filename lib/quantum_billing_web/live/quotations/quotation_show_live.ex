defmodule QuantumBillingWeb.QuotationShowLive do
  @moduledoc """
  One quotation: its status, the actions its status allows, and the document
  as it prints (the invoice design, adapted by `InvoiceDoc.QuotationLayout`).

  Draft → Sent → Accepted or Declined. An Accepted quotation converts into
  one invoice through the new-invoice form (`/invoices/new?quotation=ID`).

  An open quotation can be emailed to the client, with a link where they can
  accept or decline it themselves. Deleting moves it to the Bin.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.CustomFieldComponents, only: [any_values?: 2, custom_details: 1]

  alias QuantumBilling.CustomFields
  alias QuantumBilling.QuotationNotifier
  alias QuantumBilling.Quotations
  alias QuantumBilling.Quotations.Quotation
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Extras
  alias QuantumBillingWeb.InvoiceDoc.QuotationLayout
  alias QuantumBillingWeb.InvoiceDoc.Renderer
  alias QuantumBillingWeb.InvoicePdfGenerator

  def mount(%{"id" => id}, _session, socket) do
    case Quotations.get_quotation(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That quotation does not exist.")
         |> push_navigate(to: ~p"/quotations")}

      quotation ->
        {:ok,
         socket
         |> assign(:active_nav, :quotations)
         |> assign(
           :custom_definitions,
           CustomFields.list_definitions("quotation", archived: :include)
         )
         |> assign_quotation(quotation)
         |> assign_email_form(quotation.client_email)}
    end
  end

  defp assign_quotation(socket, quotation) do
    document = Quotations.as_document(quotation)
    {doc, accent, logo} = Templates.document_for(document)
    doc = QuotationLayout.adapt(doc)
    today = Quotations.today()

    socket
    |> assign(:page_title, quotation.number)
    |> assign(:quotation, quotation)
    |> assign(:status, Quotation.effective_status(quotation, today))
    |> assign(:convertible?, Quotations.convertible?(quotation))
    |> assign(:document, document)
    |> assign(:doc, doc)
    |> assign(:accent, accent)
    |> assign(:logo, InvoicePdfGenerator.inline_logo(logo))
    |> assign(:extras, Extras.build(document, doc, inline: true))
    |> assign(:public_url, QuotationNotifier.public_url(quotation))
  end

  defp assign_email_form(socket, to),
    do: assign(socket, :email_form, to_form(%{"to" => to || ""}, as: :email))

  def handle_event("mark_sent", _params, socket),
    do: transition(socket, &Quotations.mark_sent/2, "marked as sent")

  def handle_event("accept", _params, socket),
    do: transition(socket, &Quotations.accept/2, "accepted")

  def handle_event("decline", _params, socket),
    do: transition(socket, &Quotations.decline/2, "declined")

  def handle_event("send_email", %{"email" => %{"to" => to}}, socket) do
    %{quotation: quotation, current_scope: scope} = socket.assigns

    case Quotations.send_email(scope, quotation, to) do
      {:ok, updated, delivery} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Quotation #{updated.number} queued for delivery to #{delivery.to_email}."
         )
         |> assign_quotation(updated)
         |> assign_email_form(delivery.to_email)}

      {:error, :invalid_recipient} ->
        {:noreply,
         socket
         |> put_flash(:error, "Enter one valid email address to send the quotation to.")
         |> assign_email_form(to)}

      {:error, :expired} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This quotation has expired. Extend Valid Until before sending it."
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not queue the email: #{QuantumBilling.ErrorMessages.text(reason)}"
         )}
    end
  end

  # Quotations saved before public links existed get one on request.
  def handle_event("create_link", _params, socket) do
    case Quotations.ensure_public_token(socket.assigns.quotation) do
      {:ok, quotation} -> {:noreply, assign_quotation(socket, quotation)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "The link could not be made.")}
    end
  end

  def handle_event("delete", _params, socket) do
    quotation = socket.assigns.quotation

    case Quotations.delete_quotation(socket.assigns.current_scope, quotation) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Quotation #{quotation.number} moved to the Bin.")
         |> push_navigate(to: ~p"/quotations")}

      {:error, :converted} ->
        {:noreply, put_flash(socket, :error, "A converted quotation is kept with its invoice.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That quotation could not be deleted.")}
    end
  end

  defp transition(socket, fun, done) do
    %{quotation: quotation, current_scope: scope} = socket.assigns

    case fun.(scope, quotation) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Quotation #{updated.number} #{done}.")
         |> assign_quotation(updated)}

      {:error, :invalid_transition} ->
        # The page may be stale; show what is stored now.
        {:noreply,
         socket
         |> put_flash(:error, transition_error(socket.assigns.status))
         |> reload()}

      {:error, _reason} ->
        {:noreply, socket |> put_flash(:error, "That change could not be saved.") |> reload()}
    end
  end

  defp transition_error("Expired"),
    do: "This quotation has expired. Edit it and extend Valid Until first."

  defp transition_error(_status), do: "That isn't possible from the quotation's current status."

  defp reload(socket) do
    case Quotations.get_quotation(socket.assigns.quotation.id) do
      nil -> push_navigate(socket, to: ~p"/quotations")
      quotation -> assign_quotation(socket, quotation)
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <nav class="mb-2 flex items-center gap-1.5 text-xs text-base-content/45" aria-label="Breadcrumb">
        <.link navigate={~p"/quotations"} class="hover:text-base-content">Quotations</.link>
        <.icon name="hero-chevron-right" class="size-3" />
        <span class="text-base-content/60">{@quotation.number}</span>
      </nav>

      <.header>
        <span class="inline-flex items-center gap-2">
          {@quotation.number}
          <span id="quotation-status" data-status={@status}>
            <.status_badge status={@status} />
          </span>
        </span>
        <:subtitle>
          {@quotation.client_name} · Valid until {format_date(@quotation.valid_until)}
        </:subtitle>

        <:actions>
          <div class="flex flex-wrap items-center gap-2">
            <.link
              id="quotation-pdf"
              href={~p"/quotations/#{@quotation}/pdf"}
              target="_blank"
              class={secondary_button_class()}
            >
              <.icon name="hero-printer" class="size-4" /> Print
            </.link>
            <.link
              id="quotation-download"
              href={~p"/quotations/#{@quotation}/download"}
              class={secondary_button_class()}
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> PDF
            </.link>
            <.link
              :if={Quotation.editable?(@quotation)}
              id="edit-quotation"
              navigate={~p"/quotations/#{@quotation}/edit"}
              class={secondary_button_class()}
            >
              <.icon name="hero-pencil-square" class="size-4" /> Edit
            </.link>
            <.link
              :if={@convertible?}
              id="convert-to-invoice"
              navigate={~p"/invoices/new?#{[quotation: @quotation.id]}"}
              class={action_button_class()}
            >
              <.icon name="hero-arrow-right-circle" class="size-4" /> Convert to Invoice
            </.link>
          </div>
        </:actions>
      </.header>

      <div
        :if={Quotation.converted?(@quotation)}
        id="converted-invoice"
        class="mb-3 flex flex-wrap items-center gap-2 rounded-box border border-violet-500/30 bg-violet-500/10 px-3.5 py-2.5 text-sm"
      >
        <.icon name="hero-check-circle" class="size-4 text-violet-600 dark:text-violet-400" />
        <span>
          Converted to
          <.link
            navigate={~p"/invoices/#{@quotation.invoice.id}"}
            class="font-semibold underline-offset-2 hover:underline"
          >
            {@quotation.invoice.invoice_number}
          </.link>
        </span>
      </div>

      <.card
        :if={@quotation.status in ["Draft", "Sent"]}
        id="quotation-workflow"
        padding="px-4 py-3"
        class="mb-3"
      >
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <p class="text-sm text-base-content/70">
            {workflow_hint(@status)}
          </p>
          <div class="flex flex-wrap items-center gap-2">
            <button
              :if={@status == "Draft"}
              id="mark-sent"
              type="button"
              phx-click="mark_sent"
              phx-disable-with="Saving..."
              class={secondary_button_class()}
            >
              <.icon name="hero-paper-airplane" class="size-4" /> Mark as Sent
            </button>
            <button
              :if={@status in ["Draft", "Sent"]}
              id="accept-quotation"
              type="button"
              phx-click="accept"
              phx-disable-with="Saving..."
              class="inline-flex h-9 items-center gap-1.5 rounded-field bg-emerald-600 px-3.5 text-sm font-medium text-white shadow-sm transition-all hover:bg-emerald-700 active:scale-[0.98]"
            >
              <.icon name="hero-check" class="size-4" /> Accepted
            </button>
            <button
              id="decline-quotation"
              type="button"
              phx-click="decline"
              phx-disable-with="Saving..."
              data-confirm={"Mark #{@quotation.number} as declined? It can't be edited afterwards."}
              class="inline-flex h-9 items-center gap-1.5 rounded-field border border-rose-300 px-3.5 text-sm font-medium text-rose-700 transition-colors hover:bg-rose-50 dark:border-rose-800 dark:text-rose-300 dark:hover:bg-rose-950"
            >
              <.icon name="hero-x-mark" class="size-4" /> Declined
            </button>
          </div>
        </div>
      </.card>

      <.card id="quotation-share" padding="px-4 py-3" class="mb-3">
        <div class="grid gap-4 lg:grid-cols-2">
          <div class="min-w-0">
            <h2 class="mb-1 flex items-center gap-1.5 text-sm font-semibold tracking-tight">
              <.icon name="hero-globe-alt" class="size-4 text-base-content/50" /> Client link
            </h2>
            <p class="mb-2 text-xs text-base-content/60">
              The client can view, download and {if @status in ["Draft", "Sent"],
                do: "accept or decline",
                else: "look back at"} the quotation here. No account needed.
            </p>

            <div :if={@public_url} class="flex items-center gap-2">
              <code
                id="quotation-public-url"
                class="block min-w-0 flex-1 truncate rounded-field border border-base-300 bg-base-200/60 px-3 py-2 font-mono text-xs"
                title={@public_url}
              >
                {@public_url}
              </code>
              <button
                id="copy-quotation-link"
                type="button"
                phx-hook=".CopyQuotationLink"
                data-target="quotation-public-url"
                class={secondary_button_class()}
              >
                <.icon name="hero-clipboard-document" class="size-4" />
                <span data-label>Copy</span>
              </button>
              <.link
                id="quotation-public-link"
                href={@public_url}
                target="_blank"
                class={secondary_button_class()}
                aria-label="Open the client's page in a new tab"
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-4" />
              </.link>
            </div>

            <button
              :if={is_nil(@public_url)}
              id="create-public-link"
              type="button"
              phx-click="create_link"
              phx-disable-with="Making link..."
              class={secondary_button_class()}
            >
              <.icon name="hero-link" class="size-4" /> Make a client link
            </button>
          </div>

          <div :if={@status in ["Draft", "Sent"]} class="min-w-0">
            <h2 class="mb-1 flex items-center gap-1.5 text-sm font-semibold tracking-tight">
              <.icon name="hero-paper-airplane" class="size-4 text-base-content/50" /> Email to client
            </h2>
            <p class="mb-2 text-xs text-base-content/60">
              Sends the PDF and the client link.{if @status == "Draft",
                do: " The quotation is then marked Sent."}
            </p>
            <.form
              for={@email_form}
              id="quotation-email-form"
              phx-submit="send_email"
              class="flex items-start gap-2"
            >
              <div class="min-w-0 flex-1">
                <.input
                  field={@email_form[:to]}
                  type="email"
                  placeholder="client@example.com"
                  aria-label="Recipient email"
                  required
                />
              </div>
              <button
                id="send-quotation-email"
                type="submit"
                phx-disable-with="Queueing..."
                class={action_button_class()}
              >
                <.icon name="hero-paper-airplane" class="size-4" /> Send
              </button>
            </.form>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyQuotationLink">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const source = document.getElementById(this.el.dataset.target)
                const label = this.el.querySelector("[data-label]")
                if (!source || !navigator.clipboard) return
                navigator.clipboard.writeText(source.textContent.trim()).then(() => {
                  label.textContent = "Copied"
                  setTimeout(() => (label.textContent = "Copy"), 2000)
                })
              })
            }
          }
        </script>
      </.card>

      <.card
        :if={any_values?(@custom_definitions, @quotation.custom_fields)}
        id="quotation-custom-fields"
        class="mb-3"
      >
        <h2 class="mb-3 text-sm font-semibold tracking-tight">Details</h2>
        <.custom_details
          id="quotation-custom-values"
          definitions={@custom_definitions}
          values={@quotation.custom_fields}
          currency={@quotation.currency}
          class="grid grid-cols-1 gap-x-6 gap-y-3 sm:grid-cols-2 lg:grid-cols-4"
        />
      </.card>

      <div id="quotation-sheet-desk" class="rounded-box bg-base-200 p-3 sm:p-8">
        <div
          id="quotation-document"
          class="mx-auto aspect-[210/297] w-full max-w-[210mm] bg-white p-4 text-black shadow-xl ring-1 ring-black/5 sm:p-[12mm]"
        >
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

      <div :if={not Quotation.converted?(@quotation)} class="mt-4 flex justify-end">
        <button
          id="delete-quotation"
          type="button"
          phx-click="delete"
          data-confirm={"Move #{@quotation.number} to the Bin? It can be restored from there."}
          class="inline-flex items-center gap-1.5 rounded-field px-2.5 py-1.5 text-xs font-medium text-base-content/50 transition-colors hover:bg-rose-50 hover:text-rose-700 dark:hover:bg-rose-950 dark:hover:text-rose-300"
        >
          <.icon name="hero-trash" class="size-3.5" /> Move to Bin
        </button>
      </div>
    </Layouts.app>
    """
  end

  defp workflow_hint("Draft"), do: "Draft — send it to the client, then record their answer."
  defp workflow_hint("Sent"), do: "Waiting for the client. Record their answer when it comes."

  defp workflow_hint("Expired"),
    do: "Past its validity date. Edit it to extend Valid Until, or mark it declined."

  defp workflow_hint(_status), do: ""
end
