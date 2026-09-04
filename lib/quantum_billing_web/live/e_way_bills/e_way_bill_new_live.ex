defmodule QuantumBillingWeb.EWayBillNewLive do
  @moduledoc """
  The "Generate New E-Way Bill" form: five numbered sections on the left, a
  summary panel on the right that mirrors the form as it is filled in.

  Nothing is persisted yet — the multi-tenant Ecto schema is still pending — so
  a valid submission validates, mints an e-way bill number and reports it,
  then returns to the list.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.EWayBillsComponents

  alias QuantumBilling.EWayBills.EWayBillForm

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
     |> assign_form(changeset)}
  end

  def handle_event("validate", %{"e_way_bill" => params}, socket) do
    changeset = EWayBillForm.validate(%EWayBillForm{}, params)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"e_way_bill" => params}, socket) do
    changeset = EWayBillForm.validate(%EWayBillForm{}, params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, _form} ->
        number = EWayBillForm.generate_number()

        {:noreply,
         socket
         |> put_flash(:info, "E-Way Bill #{number} generated successfully.")
         |> push_navigate(to: ~p"/e-way-bills")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please fix the highlighted fields before generating.")
         |> assign_form(changeset)}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
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

      <div class="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <.form
          :let={f}
          for={@form}
          id="ewb-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4 lg:col-span-2"
        >
          <.form_section step="1" title="Transaction Details">
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
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

                <div class="flex h-9 items-center gap-6">
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
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div class="space-y-4">
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

              <div class="space-y-4">
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
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
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
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
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

        <div class="space-y-4 lg:sticky lg:top-16 lg:self-start">
          <.card>
            <.brand_mark class="mb-4 border-b border-base-300 pb-4" icon_class="size-6" />
            <h2 class="mb-4 text-sm font-semibold tracking-tight">E-Way Bill Summary</h2>

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
  end

  defp blank(nil), do: "—"
  defp blank(""), do: "—"
  defp blank(value), do: value
end
