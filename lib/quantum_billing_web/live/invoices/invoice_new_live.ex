defmodule QuantumBillingWeb.InvoiceNewLive do
  @moduledoc """
  The "Create New GST Invoice" form.

  Follows the shape of `ClientNewLive` and `EWayBillNewLive`: header carrying
  the actions, the form on the left and a summary rail on the right.

  The summary recomputes on every change without saving anything —
  `Invoice.recalculate/1` writes the totals onto the changeset, so the panel is
  reading the same arithmetic that will eventually be stored rather than a
  second implementation that could disagree with it.

  Picking a client copies that client's details onto the invoice. They stay
  editable afterwards: a particular invoice may legitimately need a one-off
  address, and the copy is what gets stored, so overriding it here is the
  intended way to do that.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Clients
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  def mount(_params, _session, socket) do
    organization = Settings.get_organization()
    today = Date.utc_today()

    params = %{
      "invoice_date" => Date.to_iso8601(today),
      "payment_terms" => default_term(organization),
      "due_date" => Date.to_iso8601(Date.add(today, organization.invoice_due_days || 30)),
      "place_of_supply" => organization.state,
      "terms" => organization.invoice_terms,
      "items" => %{"0" => blank_item(0)}
    }

    {:ok,
     socket
     |> assign(:page_title, "Create New GST Invoice")
     |> assign(:active_nav, :invoices)
     |> assign(:organization, organization)
     |> assign(:clients, Clients.list_clients())
     |> assign(:selected_client_id, nil)
     |> assign_form(Invoices.change_invoice(%Invoice{}, with_company(params, organization)))}
  end

  def handle_event("validate", %{"invoice" => params}, socket) do
    {params, socket} = apply_client_choice(params, socket)

    params =
      params
      |> apply_payment_term()
      |> with_company(socket.assigns.organization)

    changeset =
      %Invoice{}
      |> Invoices.change_invoice(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  # Save Draft and Preview are the same write. They differ only in the label,
  # because nothing in this scope distinguishes a previewed invoice from a
  # saved one — and validating first means clicking the "wrong" button can
  # never quietly persist an invalid invoice.
  def handle_event("save", %{"invoice" => params}, socket) do
    {params, _socket} = apply_client_choice(params, socket)
    params = apply_payment_term(params)

    case Invoices.create_invoice(params) do
      {:ok, invoice} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invoice #{invoice.invoice_number} saved as a draft.")
         |> push_navigate(to: ~p"/invoices/#{invoice.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please fix the highlighted fields.")
         |> assign_form(changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    # The totals are already on the changeset — recalculate/1 put them there —
    # so the panel and the eventual database row cannot disagree.
    invoice = Ecto.Changeset.apply_changes(changeset)

    socket
    |> assign(:form, to_form(changeset, as: "invoice"))
    |> assign(:summary, invoice)
    |> assign(:intra_state?, Invoice.intra_state?(changeset))
  end

  # Copies the chosen client's details onto the invoice, but only the moment
  # the choice changes — otherwise every keystroke would overwrite an edit the
  # user just made to one of those fields.
  #
  # The previous choice is tracked in socket state rather than a hidden input:
  # a hidden field would have to be trusted from the browser, and the server
  # already knows what it last rendered.
  defp apply_client_choice(params, socket) do
    id = params["client_id"]
    client = id not in [nil, ""] && Enum.find(socket.assigns.clients, &(to_string(&1.id) == id))

    if client && to_string(id) != to_string(socket.assigns.selected_client_id) do
      params =
        Map.merge(params, %{
          "client_name" => client.name,
          "client_gstin" => client.gstin,
          "client_pan" => client.pan,
          "client_email" => client.email,
          "client_state" => client.billing_state,
          "client_billing_address" => billing_address(client)
        })

      {params, assign(socket, :selected_client_id, id)}
    else
      {params, socket}
    end
  end

  # The issuing company, so the summary can tell intra-state from inter-state
  # while the form is being filled in. `create_invoice/1` writes these again at
  # save time from a locked read, which is the authoritative copy — this one
  # exists so the preview does not quietly show CGST/SGST for an inter-state
  # supply.
  defp with_company(params, %Organization{} = organization) do
    Map.merge(params, %{
      "company_name" => organization.company_name,
      "company_address" => organization.address,
      "company_gstin" => organization.gstin,
      "company_state" => organization.state
    })
  end

  defp billing_address(client) do
    [
      client.name,
      client.billing_line1,
      client.billing_line2,
      [client.billing_city, client.billing_state] |> Enum.reject(&is_nil/1) |> Enum.join(", "),
      client.billing_pin
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  # A named term implies the due date; "Custom" leaves whatever is in the box.
  defp apply_payment_term(params) do
    with {:ok, invoice_date} <- Date.from_iso8601(params["invoice_date"] || ""),
         %Date{} = due <- Invoice.due_date_for(invoice_date, params["payment_terms"]) do
      Map.put(params, "due_date", Date.to_iso8601(due))
    else
      _custom_or_invalid -> params
    end
  end

  defp default_term(%Organization{invoice_due_days: days}) do
    Enum.find(Invoice.payment_terms(), "Net 30 Days", &(&1 == "Net #{days} Days"))
  end

  defp blank_item(position) do
    %{
      "description" => "",
      "quantity" => "1",
      "unit" => "Nos",
      "rate" => "0",
      "tax_rate" => "18",
      "position" => to_string(position)
    }
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        Create New GST Invoice
        <:actions>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/invoices"} class={secondary_button_class()}>Cancel</.link>
            <button type="submit" form="invoice-form" class={secondary_button_class()}>
              <.icon name="hero-document-text" class="size-4" /> Save Draft
            </button>
            <button type="submit" form="invoice-form" class={action_button_class()}>
              <.icon name="hero-eye" class="size-4" /> Preview Invoice
            </button>
          </div>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <.form
          :let={f}
          for={@form}
          id="invoice-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4 lg:col-span-2"
        >
          <.card padding="p-6">
            <div class="mb-4 flex items-center gap-2.5">
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
                1
              </span>
              <h2 class="text-sm font-semibold tracking-tight">Invoice Details</h2>
            </div>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
              <.field
                field={f[:invoice_type]}
                label="Invoice Type"
                type="select"
                required
                options={Invoices.invoice_types()}
              />

              <div>
                <span class="mb-1.5 block text-xs font-medium text-base-content/60">
                  Invoice No.<span class="ml-0.5 text-error">*</span>
                </span>
                <div class="flex h-9 items-center rounded-field border border-base-300 bg-base-200 px-3 text-sm font-medium">
                  {Settings.next_invoice_number(@organization)}
                </div>
                <p class="mt-1 text-2xs text-base-content/45">
                  Assigned on save. Change the series in Settings.
                </p>
              </div>

              <.field field={f[:invoice_date]} label="Invoice Date" type="date" required />

              <.field
                field={f[:place_of_supply]}
                label="Place of Supply"
                type="select"
                required
                prompt="Select state"
                options={EWayBillForm.states()}
              />
              <.field
                field={f[:payment_terms]}
                label="Payment Terms"
                type="select"
                options={Invoices.payment_terms()}
              />
              <.field field={f[:due_date]} label="Due Date" type="date" />
            </div>
          </.card>

          <.card padding="p-6">
            <div class="mb-4 flex items-center gap-2.5">
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
                2
              </span>
              <h2 class="text-sm font-semibold tracking-tight">Client Details</h2>
            </div>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div>
                <label
                  for={f[:client_id].id}
                  class="mb-1.5 block text-xs font-medium text-base-content/60"
                >
                  Client Name<span class="ml-0.5 text-error">*</span>
                </label>
                <div class="flex gap-2">
                  <select
                    id={f[:client_id].id}
                    name={f[:client_id].name}
                    class={[form_select_class(), "min-w-0 flex-1"]}
                  >
                    <option value="">Select a client</option>
                    <option
                      :for={client <- @clients}
                      value={client.id}
                      selected={to_string(f[:client_id].value) == to_string(client.id)}
                    >
                      {client.name}
                    </option>
                  </select>
                  <.link
                    navigate={~p"/clients/new"}
                    class={[secondary_button_class(), "shrink-0"]}
                    title="Add a new client"
                  >
                    <.icon name="hero-plus" class="size-4" />
                  </.link>
                </div>
                <p :if={@clients == []} class="mt-1 text-2xs text-base-content/45">
                  No clients yet — add one first, or type the details in below.
                </p>
              </div>

              <.field
                field={f[:client_state]}
                label="State"
                type="select"
                prompt="Select state"
                options={EWayBillForm.states()}
              />

              <.field field={f[:client_name]} label="Client Name" required />
              <.field field={f[:client_gstin]} label="GSTIN" placeholder="27AABCA1234A1Z5" />

              <.field
                field={f[:client_billing_address]}
                label="Billing Address"
                type="textarea"
                rows="4"
              />

              <div class="space-y-4">
                <.field field={f[:client_pan]} label="PAN" placeholder="AABCA1234A" />
                <.field field={f[:client_email]} label="Email" type="email" />
              </div>
            </div>
          </.card>

          <.card padding="p-6">
            <div class="mb-4 flex items-center gap-2.5">
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
                3
              </span>
              <h2 class="text-sm font-semibold tracking-tight">Item Details</h2>
            </div>

            <div class="overflow-x-auto">
              <table class="w-full">
                <thead>
                  <tr class={table_head_class()}>
                    <th class="w-8 py-2 pr-2 text-left font-medium">#</th>
                    <th class="py-2 pr-2 text-left font-medium">
                      Item / Description<span class="ml-0.5 text-error">*</span>
                    </th>
                    <th class="w-28 py-2 pr-2 text-left font-medium">HSN / SAC</th>
                    <th class="w-20 py-2 pr-2 text-left font-medium">Qty</th>
                    <th class="w-24 py-2 pr-2 text-left font-medium">Unit</th>
                    <th class="w-28 py-2 pr-2 text-left font-medium">Rate (₹)</th>
                    <th class="w-24 py-2 pr-2 text-left font-medium">Tax (%)</th>
                    <th class="w-28 py-2 pr-2 text-right font-medium">Amount (₹)</th>
                    <th class="w-10 py-2 text-right font-medium">
                      <span class="sr-only">Remove</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={{item, index} <- Enum.with_index(f[:items].value || [])}
                    class={table_row_class()}
                  >
                    <% item_form = to_form(item, as: "invoice[items][#{index}]") %>
                    <td class="py-2 pr-2 align-top text-sm text-base-content/45">{index + 1}</td>
                    <td class="py-2 pr-2 align-top">
                      <input type="hidden" name="invoice[items_sort][]" value={index} />
                      <input
                        type="hidden"
                        name={item_form[:position].name}
                        value={index}
                      />
                      <input
                        type="text"
                        name={item_form[:description].name}
                        value={Phoenix.HTML.Form.input_value(item_form, :description)}
                        placeholder="Item or service"
                        required
                        class={form_input_class()}
                      />
                    </td>
                    <td class="py-2 pr-2 align-top">
                      <input
                        type="text"
                        name={item_form[:hsn_sac].name}
                        value={Phoenix.HTML.Form.input_value(item_form, :hsn_sac)}
                        placeholder="998313"
                        class={form_input_class()}
                      />
                    </td>
                    <td class="py-2 pr-2 align-top">
                      <input
                        type="number"
                        min="1"
                        name={item_form[:quantity].name}
                        value={Phoenix.HTML.Form.input_value(item_form, :quantity)}
                        class={form_input_class()}
                      />
                    </td>
                    <td class="py-2 pr-2 align-top">
                      <select name={item_form[:unit].name} class={form_select_class()}>
                        <option
                          :for={unit <- InvoiceItem.units()}
                          value={unit}
                          selected={Phoenix.HTML.Form.input_value(item_form, :unit) == unit}
                        >
                          {unit}
                        </option>
                      </select>
                    </td>
                    <td class="py-2 pr-2 align-top">
                      <input
                        type="number"
                        min="0"
                        name={item_form[:rate].name}
                        value={Phoenix.HTML.Form.input_value(item_form, :rate)}
                        class={form_input_class()}
                      />
                    </td>
                    <td class="py-2 pr-2 align-top">
                      <select name={item_form[:tax_rate].name} class={form_select_class()}>
                        <option
                          :for={rate <- Organization.gst_rates()}
                          value={rate}
                          selected={
                            to_string(Phoenix.HTML.Form.input_value(item_form, :tax_rate)) ==
                              to_string(rate)
                          }
                        >
                          {rate}%
                        </option>
                      </select>
                    </td>
                    <td class="py-2 pr-2 text-right align-middle text-sm font-medium">
                      {rupees(line_amount(item), decimals: 2)}
                    </td>
                    <td class="py-2 text-right align-middle">
                      <label class={[row_action_class(), "ml-auto cursor-pointer"]}>
                        <input
                          type="checkbox"
                          name="invoice[items_drop][]"
                          value={index}
                          class="hidden"
                        />
                        <.icon name="hero-trash" class="size-4" />
                      </label>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p
              :for={msg <- item_errors(@form)}
              class="mt-2 flex items-center gap-1 text-2xs text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />{msg}
            </p>

            <label class={[secondary_button_class(), "mt-4 cursor-pointer"]}>
              <input type="checkbox" name="invoice[items_sort][]" class="hidden" />
              <.icon name="hero-plus" class="size-4" /> Add New Item
            </label>
          </.card>

          <.card padding="p-6">
            <div class="mb-4 flex items-center gap-2.5">
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
                4
              </span>
              <h2 class="text-sm font-semibold tracking-tight">Additional Information</h2>
            </div>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
              <.field
                field={f[:remarks]}
                label="Remarks"
                type="textarea"
                rows="4"
                placeholder="Enter remarks (if any)"
              />
              <.field
                field={f[:terms]}
                label="Terms & Conditions"
                type="textarea"
                rows="4"
                placeholder="Enter terms and conditions (if any)"
              />

              <div>
                <span class="mb-1.5 block text-xs font-medium text-base-content/60">
                  Attachments
                </span>
                <div class="flex h-[6.5rem] flex-col items-center justify-center rounded-field border border-dashed border-base-300 px-3 text-center">
                  <.icon name="hero-paper-clip" class="size-4 text-base-content/45" />
                  <p class="mt-1 text-xs text-base-content/45">Needs file storage</p>
                </div>
              </div>
            </div>
          </.card>
        </.form>

        <div class="space-y-4 lg:sticky lg:top-16 lg:self-start">
          <.card>
            <h2 class="mb-4 text-sm font-semibold tracking-tight">Invoice Summary</h2>

            <div class="space-y-2.5">
              <.summary_line label="Total Items" value={@summary.total_items} />
              <.summary_line label="Total Quantity" value={@summary.total_quantity} />
              <.summary_line
                label="Total Taxable Value"
                value={rupees(@summary.taxable_value, decimals: 2, space: true)}
              />
            </div>

            <hr class="my-4 border-base-300" />

            <div class="space-y-2.5">
              <.summary_line
                label="CGST"
                value={rupees(@summary.cgst_amount, decimals: 2, space: true)}
              />
              <.summary_line
                label="SGST"
                value={rupees(@summary.sgst_amount, decimals: 2, space: true)}
              />
              <.summary_line
                label="IGST"
                value={rupees(@summary.igst_amount, decimals: 2, space: true)}
              />
              <.summary_line
                label="CESS"
                value={rupees(@summary.cess_amount, decimals: 2, space: true)}
              />
            </div>

            <hr class="my-4 border-base-300" />

            <.summary_line
              label="Round Off"
              value={rupees(@summary.round_off, decimals: 2, space: true)}
            />

            <div class="mt-4 flex items-start justify-between gap-4 rounded-field bg-base-200 px-3 py-2.5">
              <span class="text-sm font-semibold">Grand Total</span>
              <span class="text-sm font-semibold tracking-tight">
                {rupees(@summary.grand_total, decimals: 2, space: true)}
              </span>
            </div>

            <p class="mt-3 text-2xs uppercase tracking-wider text-base-content/45">
              Amount in Words
            </p>
            <p class="mt-1 text-xs text-base-content/60">
              {QuantumBillingWeb.Format.rupees_in_words(@summary.grand_total)}
            </p>

            <p class="mt-3 text-2xs text-base-content/45">
              {if @intra_state?,
                do: "Same state as your business — CGST and SGST apply.",
                else: "Different state from your business — IGST applies."}
            </p>
          </.card>

          <.card>
            <div class="flex items-start justify-between gap-4">
              <h2 class="text-sm font-semibold tracking-tight">From (Your Company)</h2>
              <.link
                navigate={~p"/settings"}
                class="flex items-center gap-1 text-xs text-base-content/60 hover:text-base-content"
              >
                <.icon name="hero-pencil-square" class="size-3.5" /> Edit
              </.link>
            </div>

            <div :if={@organization.company_name} class="mt-3 space-y-1 text-xs">
              <p class="text-sm font-medium">{@organization.company_name}</p>
              <p :if={@organization.address} class="whitespace-pre-line text-base-content/60">
                {@organization.address}
              </p>
              <p :if={@organization.gstin} class="text-base-content/60">
                GSTIN: {@organization.gstin}
              </p>
              <p :if={@organization.state} class="text-base-content/60">
                State: {@organization.state}
              </p>
            </div>

            <p :if={is_nil(@organization.company_name)} class="mt-3 text-xs text-base-content/60">
              Your company details are not set up yet. Add them in Settings so they appear on
              every invoice.
            </p>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp summary_line(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <span class="text-xs text-base-content/60">{@label}</span>
      <span class="text-right text-xs font-medium">{@value}</span>
    </div>
    """
  end

  # The line total as typed, before anything is saved.
  defp line_amount(%Ecto.Changeset{} = changeset) do
    quantity = Ecto.Changeset.get_field(changeset, :quantity) || 0
    rate = Ecto.Changeset.get_field(changeset, :rate) || 0
    quantity * rate
  end

  defp line_amount(%InvoiceItem{} = item), do: InvoiceItem.amount(item)
  defp line_amount(_other), do: 0

  # `cast_assoc` reports "add at least one item" against :items, which no
  # individual input owns, so it is surfaced under the table instead.
  defp item_errors(form) do
    form.source.errors
    |> Keyword.get_values(:items)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end
