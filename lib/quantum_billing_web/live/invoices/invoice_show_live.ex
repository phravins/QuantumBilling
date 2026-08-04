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
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Settings
  alias QuantumBillingWeb.Format
  alias QuantumBillingWeb.InvoiceDocument

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
        config = InvoiceDocument.config(Settings.get_organization())

        {:ok,
         socket
         |> assign(:page_title, invoice.invoice_number)
         |> assign(:active_nav, :invoices)
         |> assign(:invoice, invoice)
         |> assign(:doc, config)
         |> assign(:heading, InvoiceDocument.heading(config, invoice))
         |> assign(:show_cess?, InvoiceDocument.show_cess?(config, invoice))}
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
          <div class="flex items-center gap-2">
            <.status_badge status={@invoice.status} />
            <.link navigate={~p"/invoices"} class={secondary_button_class()}>
              <.icon name="hero-arrow-left" class="size-4" /> Back to Invoices
            </.link>
          </div>
        </:actions>
      </.header>

      <.card padding="p-8">
        <div class="flex flex-col gap-6 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <img :if={@doc.logo} src={@doc.logo} alt="" class="mb-5 max-h-14 max-w-52" />
            <.brand_mark
              :if={is_nil(@doc.logo)}
              class="mb-5"
              icon_class="size-7"
              label_class="text-base font-semibold tracking-tight"
            />

            <p class="text-2xs uppercase tracking-wider text-base-content/45">From</p>
            <p class="mt-1 text-sm font-semibold tracking-tight">
              {@invoice.company_name || "—"}
            </p>
            <p
              :if={@invoice.company_address}
              class="mt-1 whitespace-pre-line text-sm text-base-content/60"
            >
              {@invoice.company_address}
            </p>
            <p :if={@invoice.company_gstin} class="mt-1 text-sm text-base-content/60">
              GSTIN: {@invoice.company_gstin}
            </p>
            <p :if={@invoice.company_state} class="text-sm text-base-content/60">
              State: {@invoice.company_state}
            </p>
          </div>

          <dl class="space-y-1 text-sm sm:text-right">
            <div class="mb-2 sm:text-right">
              <p class="text-base font-semibold tracking-tight" style={"color: #{@doc.accent}"}>
                {@heading}
              </p>
            </div>
            <div class="flex gap-3 sm:justify-end">
              <dt class="text-base-content/60">Invoice Date</dt>
              <dd class="font-medium">{Format.format_date(@invoice.invoice_date)}</dd>
            </div>
            <div class="flex gap-3 sm:justify-end">
              <dt class="text-base-content/60">Due Date</dt>
              <dd class="font-medium">{Format.format_date(@invoice.due_date)}</dd>
            </div>
            <div :if={@invoice.payment_terms} class="flex gap-3 sm:justify-end">
              <dt class="text-base-content/60">Payment Terms</dt>
              <dd class="font-medium">{@invoice.payment_terms}</dd>
            </div>
            <div class="flex gap-3 sm:justify-end">
              <dt class="text-base-content/60">Place of Supply</dt>
              <dd class="font-medium">{@invoice.place_of_supply}</dd>
            </div>
          </dl>
        </div>

        <hr class="my-6 border-base-300" />

        <div>
          <p class="text-2xs uppercase tracking-wider text-base-content/45">Bill To</p>
          <p class="mt-1 text-sm font-semibold tracking-tight">{@invoice.client_name}</p>
          <p
            :if={@invoice.client_billing_address}
            class="mt-1 whitespace-pre-line text-sm text-base-content/60"
          >
            {@invoice.client_billing_address}
          </p>
          <p :if={@invoice.client_gstin} class="mt-1 text-sm text-base-content/60">
            GSTIN: {@invoice.client_gstin}
          </p>
          <p :if={@invoice.client_email} class="text-sm text-base-content/60">
            {@invoice.client_email}
          </p>
        </div>

        <div class="mt-6 overflow-x-auto">
          <table class="w-full">
            <thead>
              <tr class={table_head_class()}>
                <th class="w-8 pr-4 text-left">#</th>
                <th class="pr-4 text-left">Item / Description</th>
                <th :if={@doc.show_hsn} class="pr-4 text-left">HSN / SAC</th>
                <th class="pr-4 text-right">Qty</th>
                <th :if={@doc.show_unit} class="pr-4 text-left">Unit</th>
                <th class="pr-4 text-right">Rate (₹)</th>
                <th :if={@doc.show_tax_rate} class="pr-4 text-right">Tax (%)</th>
                <th class="text-right">Amount (₹)</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{item, index} <- Enum.with_index(@invoice.items, 1)}
                id={"invoice-item-#{item.id}"}
                class={table_row_class()}
              >
                <td class="py-2.5 pr-4 text-base-content/45">{index}</td>
                <td class="py-2.5 pr-4 font-medium">{item.description}</td>
                <td :if={@doc.show_hsn} class="py-2.5 pr-4 text-base-content/60">
                  {item.hsn_sac || "—"}
                </td>
                <td class="py-2.5 pr-4 text-right">{item.quantity}</td>
                <td :if={@doc.show_unit} class="py-2.5 pr-4 text-base-content/60">{item.unit}</td>
                <td class="py-2.5 pr-4 text-right">{rupees(item.rate, decimals: 2)}</td>
                <td :if={@doc.show_tax_rate} class="py-2.5 pr-4 text-right text-base-content/60">
                  {item.tax_rate}%
                </td>
                <td class="py-2.5 text-right font-medium">{rupees(item.amount, decimals: 2)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="mt-6 flex justify-end">
          <dl class="w-full max-w-xs space-y-2 text-sm">
            <.total_line
              label="Taxable Value"
              value={rupees(@invoice.taxable_value, decimals: 2, space: true)}
            />
            <.total_line
              :if={Invoice.intra_state?(@invoice)}
              label="CGST"
              value={rupees(@invoice.cgst_amount, decimals: 2, space: true)}
            />
            <.total_line
              :if={Invoice.intra_state?(@invoice)}
              label="SGST"
              value={rupees(@invoice.sgst_amount, decimals: 2, space: true)}
            />
            <.total_line
              :if={not Invoice.intra_state?(@invoice)}
              label="IGST"
              value={rupees(@invoice.igst_amount, decimals: 2, space: true)}
            />
            <.total_line
              :if={@show_cess?}
              label="Cess"
              value={rupees(@invoice.cess_amount, decimals: 2, space: true)}
            />
            <.total_line
              label="Round Off"
              value={rupees(@invoice.round_off, decimals: 2, space: true)}
            />

            <div
              class="flex items-center justify-between gap-4 rounded-field border-t-2 bg-base-200 px-3 py-2.5"
              style={"border-color: #{@doc.accent}"}
            >
              <dt class="font-semibold">Grand Total</dt>
              <dd class="font-semibold tracking-tight" style={"color: #{@doc.accent}"}>
                {rupees(@invoice.grand_total, decimals: 2, space: true)}
              </dd>
            </div>
          </dl>
        </div>

        <div :if={@doc.show_amount_words} class="mt-6 border-t border-base-300 pt-4">
          <p class="text-2xs uppercase tracking-wider text-base-content/45">Amount in Words</p>
          <p class="mt-1 text-sm">{Format.rupees_in_words(@invoice.grand_total)}</p>
        </div>

        <div
          :if={(@doc.show_remarks and @invoice.remarks) || @invoice.terms}
          class="mt-6 grid grid-cols-1 gap-6 border-t border-base-300 pt-4 sm:grid-cols-2"
        >
          <div :if={@doc.show_remarks and @invoice.remarks}>
            <p class="text-2xs uppercase tracking-wider text-base-content/45">Remarks</p>
            <p class="mt-1 whitespace-pre-line text-sm text-base-content/60">{@invoice.remarks}</p>
          </div>
          <div :if={@invoice.terms}>
            <p class="text-2xs uppercase tracking-wider text-base-content/45">
              Terms &amp; Conditions
            </p>
            <p class="mt-1 whitespace-pre-line text-sm text-base-content/60">{@invoice.terms}</p>
          </div>
        </div>

        <p
          :if={@doc.footer}
          class="mt-6 whitespace-pre-line border-t border-base-300 pt-4 text-center text-sm text-base-content/60"
        >
          {@doc.footer}
        </p>
      </.card>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp total_line(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4">
      <dt class="text-base-content/60">{@label}</dt>
      <dd class="font-medium">{@value}</dd>
    </div>
    """
  end
end
