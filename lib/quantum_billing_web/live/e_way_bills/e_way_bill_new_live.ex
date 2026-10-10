defmodule QuantumBillingWeb.EWayBillNewLive do
  @moduledoc """
  The "Generate New E-Way Bill" form: five numbered sections on the left, a
  summary panel on the right that mirrors the form as it is filled in.

  ## It issues a real bill now

  Submitting used to validate the form, mint a random twelve-digit number into
  a flash message and throw it away: nothing was stored, no document existed,
  and the number the user was congratulated with appeared nowhere on the
  e-way bill list they were returned to.

  A bill is raised against a document, so the form loads a consignment from an
  invoice — `Invoices.awaiting_e_way_bill/1` — and submitting runs the real
  `EWayBills.generate_e_way_bill/2`, which calls the portal, stores the number
  and validity on that invoice and lands on the printed EWB-01. A document
  number that matches no invoice is a form error, not a silent success.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.EWayBillsComponents

  alias QuantumBilling.EWayBills
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.EWayBills.Validity
  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings

  @defaults %{
    supply_type: "Outward Supply",
    sub_type: "Supply",
    document_type: "Tax Invoice",
    transaction_type: "Regular",
    transport_mode: "Road",
    cgst_value: 0,
    sgst_value: 0,
    igst_value: 0,
    other_amount: 0
  }

  def mount(_params, _session, socket) do
    changeset = EWayBillForm.changeset(%EWayBillForm{}, @defaults)

    {:ok,
     socket
     |> assign(:page_title, "Generate New E-Way Bill")
     |> assign(:active_nav, :e_way_bills)
     |> assign(:selected_invoice_id, nil)
     |> assign_invoice_options()
     |> assign_form(changeset)}
  end

  def handle_event("validate", %{"e_way_bill" => params}, socket) do
    changeset = EWayBillForm.validate(%EWayBillForm{}, params)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("load_invoice", %{"invoice_id" => ""}, socket) do
    {:noreply,
     socket
     |> assign(:selected_invoice_id, nil)
     |> assign_form(EWayBillForm.changeset(%EWayBillForm{}, @defaults))}
  end

  def handle_event("load_invoice", %{"invoice_id" => id}, socket) do
    case Invoices.get_invoice(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That invoice could not be loaded.")}

      invoice ->
        {:noreply,
         socket
         |> assign(:selected_invoice_id, to_string(invoice.id))
         |> assign_form(EWayBillForm.changeset(%EWayBillForm{}, prefill(invoice)))}
    end
  end

  def handle_event("save", %{"e_way_bill" => params}, socket) do
    changeset = EWayBillForm.validate(%EWayBillForm{}, params)

    with {:ok, form} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, invoice} <- fetch_document(form) do
      generate(socket, invoice, form, changeset)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please fix the highlighted fields before generating.")
         |> assign_form(changeset)}

      {:error, {:no_document, document_no}} ->
        {:noreply,
         socket
         |> put_flash(:error, "No invoice numbered #{document_no} exists.")
         |> assign_form(document_error(changeset, "no invoice with this number"))}

      {:error, {:already_issued, invoice, bill}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "#{invoice.invoice_number} already carries e-way bill #{bill.ewb_number}."
         )
         |> assign_form(document_error(changeset, "already has an e-way bill"))}
    end
  end

  defp generate(socket, invoice, form, changeset) do
    case EWayBills.generate_e_way_bill(invoice, transport_params(form)) do
      {:ok, bill} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "E-Way Bill #{bill.ewb_number} generated for #{bill.invoice.invoice_number}."
         )
         |> redirect(to: ~p"/e-way-bills/#{bill.id}/print")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not generate the e-way bill: #{inspect(reason)}")
         |> assign_form(changeset)}
    end
  end

  # Only the live bill blocks a new one; Rule 138(9) allows reissue after cancelling.
  defp fetch_document(%EWayBillForm{document_no: document_no}) do
    case Invoices.get_invoice_by_number(String.trim(document_no || "")) do
      nil ->
        {:error, {:no_document, document_no}}

      invoice ->
        case EWayBills.live_bill_for_invoice(invoice.id) do
          nil -> {:ok, invoice}
          bill -> {:error, {:already_issued, invoice, bill}}
        end
    end
  end

  defp transport_params(%EWayBillForm{} = form) do
    %{
      "distance_km" => form.distance_km,
      "vehicle_number" => form.vehicle_no,
      "mode_of_transport" => form.transport_mode,
      "transporter_id" => form.transporter_id,
      "transporter_name" => form.transporter_name
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp document_error(changeset, message) do
    changeset
    |> Ecto.Changeset.add_error(:document_no, message)
    |> Map.put(:action, :validate)
  end

  defp assign_invoice_options(socket) do
    options =
      Enum.map(Invoices.awaiting_e_way_bill(), fn invoice ->
        label =
          "#{invoice.invoice_number} · #{invoice.client_name} · " <>
            rupees(invoice.grand_total || 0)

        {label, invoice.id}
      end)

    assign(socket, :invoice_options, options)
  end

  # Unrecognised states are dropped rather than prefilled.
  defp prefill(invoice) do
    organization = Settings.get_organization()

    %{
      supply_type: "Outward Supply",
      sub_type: "Supply",
      document_type: document_type(invoice.invoice_type),
      document_no: invoice.invoice_number,
      document_date: invoice.invoice_date,
      transaction_type: "Regular",
      from_party: invoice.company_name,
      from_gstin: invoice.company_gstin,
      from_state: known_state(invoice.company_state),
      to_party: invoice.client_name,
      to_gstin: invoice.client_gstin,
      to_state: known_state(invoice.client_state || invoice.place_of_supply),
      total_goods_value: invoice.taxable_value,
      cgst_value: invoice.cgst_amount,
      sgst_value: invoice.sgst_amount,
      igst_value: invoice.igst_amount,
      other_amount: invoice.cess_amount,
      # Transport details come from the organisation's saved defaults.
      transport_mode: organization_field(organization, :ewb_transport_mode) || "Road",
      transporter_name: nil,
      transporter_id: organization_field(organization, :ewb_transporter_id),
      vehicle_no: nil,
      distance_km: nil,
      from_place: organization_field(organization, :city) || state_name(invoice.company_state),
      to_place: invoice.client_city || state_name(invoice.client_state)
    }
  end

  defp organization_field(nil, _field), do: nil
  defp organization_field(organization, field), do: Map.get(organization, field)

  defp document_type(type) do
    if type in EWayBillForm.document_types(), do: type, else: "Tax Invoice"
  end

  defp known_state(state) do
    if state in EWayBillForm.states(), do: state, else: nil
  end

  defp state_name(nil), do: nil
  defp state_name(state), do: state |> String.replace(~r/\s*\(\d+\)$/, "") |> String.trim()

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        <span class="inline-flex items-center gap-2">
          Generate New E-Way Bill
          <.help_popover id="ewb-help" label="Before you generate this e-way bill">
            <span class="flex gap-2.5">
              <.icon name="hero-information-circle" class="size-4 shrink-0 text-base-content/45" />
              <span class="block">
                <span class="block font-medium">Note</span>
                <span class="mt-1 block text-base-content/60">
                  Please verify all details before generating the e-way bill. Once generated,
                  only the vehicle number can be updated.
                </span>
              </span>
            </span>
          </.help_popover>
        </span>

        <:subtitle>Fill in the consignment details to generate a new e-way bill</:subtitle>

        <:actions>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/e-way-bills"} class={secondary_button_class()}>Cancel</.link>
            <button type="submit" form="ewb-form" class={action_button_class()}>
              <.icon name="hero-document-check" class="size-4" /> Generate E-Way Bill
            </button>
          </div>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 gap-3 lg:grid-cols-3">
        <div class="space-y-3 lg:col-span-2">
          <.card>
            <form id="ewb-load-invoice" phx-change="load_invoice">
              <.input
                type="select"
                name="invoice_id"
                value={@selected_invoice_id}
                label="Load from an invoice"
                prompt={
                  if @invoice_options == [],
                    do: "No invoices are waiting for an e-way bill",
                    else: "Select the invoice this consignment is for"
                }
                options={@invoice_options}
              />
            </form>

            <p class="mt-2 text-2xs text-base-content/45">
              The document number has to match an invoice you have already
              issued — the portal raises one e-way bill per document.
            </p>
          </.card>

          <.form
            :let={f}
            for={@form}
            id="ewb-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-3"
          >
            <.form_section step="1" title="Transaction Details">
              <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
                <.field
                  field={f[:supply_type]}
                  label="Supply Type"
                  type="select"
                  required
                  options={EWayBillForm.supply_types()}
                />
                <.field
                  field={f[:sub_type]}
                  label="Sub Type"
                  type="select"
                  required
                  options={EWayBillForm.sub_types()}
                />
                <.field
                  field={f[:document_type]}
                  label="Document Type"
                  type="select"
                  required
                  options={EWayBillForm.document_types()}
                />
                <.field
                  field={f[:document_no]}
                  label="Document No."
                  required
                  placeholder="Document number"
                /> <.field field={f[:document_date]} label="Document Date" type="date" required />
                <div class="sm:col-span-2">
                  <span class="mb-1.5 block text-xs font-medium text-base-content/60">
                    Transaction Type<span class="ml-0.5 text-error">*</span>
                  </span>

                  <div class="flex h-9 items-center gap-4">
                    <.radio_option
                      :for={type <- EWayBillForm.transaction_types()}
                      field={f[:transaction_type]}
                      value={type}
                      label={type}
                    />
                  </div>
                </div>
              </div>
            </.form_section>

            <.form_section step="2" title="Parties Details">
              <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <div class="space-y-3">
                  <.field
                    field={f[:from_party]}
                    label="From (Dispatch From)"
                    required
                    placeholder="Consignor name"
                  />
                  <.field
                    field={f[:from_gstin]}
                    label="From GSTIN"
                    placeholder="27AABCA1234A1Z5"
                    hint="15-character GSTIN of the consignor"
                  />
                  <.field
                    field={f[:from_state]}
                    label="State"
                    type="select"
                    required
                    prompt="Select state"
                    options={EWayBillForm.states()}
                  />
                </div>

                <div class="space-y-3">
                  <.field
                    field={f[:to_party]}
                    label="To (Ship To)"
                    required
                    placeholder="Consignee name"
                  />
                  <.field
                    field={f[:to_gstin]}
                    label="To GSTIN"
                    placeholder="27AAACP8542D1ZS"
                    hint="15-character GSTIN of the consignee"
                  />
                  <.field
                    field={f[:to_state]}
                    label="State"
                    type="select"
                    required
                    prompt="Select state"
                    options={EWayBillForm.states()}
                  />
                </div>
              </div>
            </.form_section>

            <.form_section step="3" title="Item Details">
              <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
                <.field
                  field={f[:total_goods_value]}
                  label="Total Value of Goods"
                  type="number"
                  required
                  min="0"
                  placeholder="60000"
                /> <.field field={f[:cgst_value]} label="Total CGST Value" type="number" min="0" />
                <.field field={f[:sgst_value]} label="Total SGST Value" type="number" min="0" />
                <.field field={f[:igst_value]} label="Total IGST Value" type="number" min="0" />
                <.field field={f[:other_amount]} label="Other Amount (+)" type="number" min="0" />
                <div class="sm:col-span-2">
                  <span class="mb-1.5 block text-xs font-medium text-base-content/60">
                    Total Invoice Value
                  </span>

                  <div
                    id="total-invoice-value"
                    class="flex h-9 items-center rounded-field border border-base-300 bg-base-200 px-3 text-sm font-semibold"
                  >
                    {rupees(@total_invoice_value, decimals: 2, space: true)}
                  </div>
                </div>
              </div>
            </.form_section>

            <.form_section step="4" title="Transport Details">
              <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
                <.field
                  field={f[:transport_mode]}
                  label="Transport Mode"
                  type="select"
                  required
                  options={EWayBillForm.transport_modes()}
                />
                <.field
                  field={f[:transporter_name]}
                  label="Transporter Name"
                  placeholder="Transporter name"
                />
                <.field
                  field={f[:transporter_id]}
                  label="Transporter ID"
                  placeholder="27ABCDE1234F1Z5"
                />
                <.field
                  field={f[:vehicle_no]}
                  label="Vehicle No."
                  required
                  placeholder="MH01AB1234"
                  hint="Format: MH01AB1234"
                /> <.field field={f[:from_place]} label="From Place" required placeholder="Mumbai" />
                <.field field={f[:to_place]} label="To Place" required placeholder="Pune" />
                <.field
                  field={f[:distance_km]}
                  label="Approx. Distance (km)"
                  type="number"
                  required
                  min="1"
                  placeholder="250"
                  hint="One day of validity per 200 km"
                />
              </div>
            </.form_section>

            <.form_section step="5" title="Other Details (Optional)">
              <.field
                field={f[:remarks]}
                label="Remarks"
                type="textarea"
                rows="3"
                placeholder="Enter remarks (optional)"
              />
              <p class="mt-1 text-right text-2xs text-base-content/45">
                {@remarks_length} / 500
              </p>
            </.form_section>
          </.form>
        </div>

        <div class="space-y-3 lg:sticky lg:top-16 lg:self-start">
          <.card>
            <.brand_mark class="mb-3 border-b border-base-300 pb-4" icon_class="size-6" />
            <h2 class="mb-2.5 text-sm font-semibold tracking-tight">E-Way Bill Summary</h2>

            <div class="space-y-2.5">
              <.summary_row label="Supply Type" value={@summary.supply_type} />
              <.summary_row label="Sub Type" value={@summary.sub_type} />
              <.summary_row label="Document Type" value={@summary.document_type} />
              <.summary_row label="Document No." value={@summary.document_no} />
              <.summary_row label="Document Date" value={format_date(@summary.document_date)} />
              <.summary_row label="Transaction Type" value={@summary.transaction_type} />
            </div>
            <hr class="my-4 border-base-300" />
            <div class="space-y-2.5">
              <.summary_row label="From">
                <span class="block">{blank(@summary.from_party)}</span>
                <span :if={@summary.from_gstin} class="block text-base-content/60">
                  {@summary.from_gstin}
                </span>

                <span :if={@summary.from_state} class="block text-base-content/60">
                  {@summary.from_state}
                </span>
              </.summary_row>

              <.summary_row label="To">
                <span class="block">{blank(@summary.to_party)}</span>
                <span :if={@summary.to_gstin} class="block text-base-content/60">
                  {@summary.to_gstin}
                </span>

                <span :if={@summary.to_state} class="block text-base-content/60">
                  {@summary.to_state}
                </span>
              </.summary_row>

              <.summary_row label="Route">
                {blank(@summary.from_place)} &rarr; {blank(@summary.to_place)}
              </.summary_row>
              <.summary_row label="Vehicle No." value={@summary.vehicle_no} />
              <.summary_row
                label="Approx. Distance"
                value={if @summary.distance_km, do: "#{@summary.distance_km} km"}
              />
              <.summary_row label="Validity" value={@validity} />
            </div>
            <hr class="my-4 border-base-300" />
            <div class="space-y-2.5">
              <.summary_row
                label="Total Value of Goods"
                value={rupees(@summary.total_goods_value || 0, decimals: 2, space: true)}
              />
              <.summary_row
                label="CGST"
                value={rupees(@summary.cgst_value || 0, decimals: 2, space: true)}
              />
              <.summary_row
                label="SGST"
                value={rupees(@summary.sgst_value || 0, decimals: 2, space: true)}
              />
              <.summary_row
                label="IGST"
                value={rupees(@summary.igst_value || 0, decimals: 2, space: true)}
              />
              <.summary_row
                label="Other Amount"
                value={rupees(@summary.other_amount || 0, decimals: 2, space: true)}
              />
            </div>

            <div class="mt-4">
              <.summary_row
                label="Total Invoice Value"
                value={rupees(@total_invoice_value, decimals: 2, space: true)}
                emphasis
              />
            </div>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    summary = Ecto.Changeset.apply_changes(changeset)

    socket
    |> assign(:form, to_form(changeset, as: "e_way_bill"))
    |> assign(:summary, summary)
    |> assign(:total_invoice_value, EWayBillForm.total_invoice_value(changeset))
    |> assign(:remarks_length, String.length(summary.remarks || ""))
    |> assign(:validity, validity(summary.distance_km))
  end

  defp validity(nil), do: nil

  defp validity(distance_km) do
    days = Validity.days(distance_km)
    until = Date.add(Date.utc_today(), days)

    "#{days} #{if days == 1, do: "day", else: "days"} · until #{format_date(until)}"
  end

  defp blank(nil), do: "—"
  defp blank(""), do: "—"
  defp blank(value), do: value
end
