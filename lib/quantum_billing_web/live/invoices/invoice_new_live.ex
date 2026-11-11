defmodule QuantumBillingWeb.InvoiceNewLive do
  @moduledoc """
  The invoice form: header actions, the form, and a live summary rail.

  The summary uses `Invoice.recalculate/1`, the same arithmetic that is stored.
  Picking a client, or typing its exact name, copies its details, which stay
  editable. An empty PAN is filled from the GSTIN.

  Under VAT each line picks one of the business's rates, place of supply is not
  asked, and the summary shows a row per rate.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.CustomFieldComponents,
    only: [custom_fields_section: 1, custom_inputs: 1]

  import QuantumBillingWeb.SettingsComponents, only: [toggle: 1]

  alias QuantumBilling.Clients
  alias QuantumBilling.CustomFields
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.GST
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Money
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Tax
  alias QuantumBilling.TaxRates
  alias QuantumBilling.TaxRates.TaxRate
  alias QuantumBilling.Templates

  # Serves both new and edit.
  def mount(params, _session, socket) do
    organization = Settings.get_organization()

    socket =
      socket
      |> assign(:active_nav, :invoices)
      |> assign(:organization, organization)
      |> assign(:custom_definitions, CustomFields.active_definitions("invoice"))
      |> assign(:item_definitions, CustomFields.active_definitions("invoice_item"))
      |> assign(:client_search, "")
      |> assign(:selected_client_id, nil)
      |> assign(:gstin_hint, nil)
      |> assign_client_options()
      # Read-only: opening the form must not create a design.
      |> assign(:template_options, template_options())

    case params do
      %{"id" => id} -> mount_edit(id, organization, socket)
      _new -> {:ok, mount_new(organization, socket)}
    end
  end

  # Empty when no design exists; the picker is then hidden.
  defp template_options do
    Enum.map(Templates.list_templates(), fn template -> {template.name, template.id} end)
  end

  defp mount_new(organization, socket) do
    today = Date.utc_today()

    params = %{
      "invoice_date" => Date.to_iso8601(today),
      "payment_terms" => default_term(organization),
      "due_date" => Date.to_iso8601(Date.add(today, organization.invoice_due_days || 30)),
      "place_of_supply" => organization.state,
      "terms" => organization.invoice_terms,
      "items" => %{"0" => blank_item(0)}
    }

    vat? = Organization.vat?(organization)

    socket
    |> assign(:page_title, if(vat?, do: "Create New Invoice", else: "Create New GST Invoice"))
    |> assign(:invoice, %Invoice{})
    |> assign(:currency, Organization.currency_code(organization))
    |> assign_tax(vat?)
    |> assign_form(
      Invoices.change_invoice(%Invoice{}, params, preview_trusted(organization, %Invoice{}))
    )
  end

  # The rate picker offers active rates; an archived one stays listed for the lines using it.
  defp assign_tax(socket, vat?) do
    socket
    |> assign(:vat?, vat?)
    |> assign(:tax_rates, if(vat?, do: TaxRates.list_rates(archived: :include), else: []))
  end

  # The company goes in as trusted, so the live preview splits the tax correctly;
  # the save takes its own snapshot. A new invoice also previews the business's
  # tax settings, which an existing one keeps from when it was created.
  defp preview_trusted(organization, %Invoice{id: nil}) do
    organization
    |> Invoices.company_snapshot()
    |> Map.merge(Organization.invoice_tax_snapshot(organization))
  end

  defp preview_trusted(organization, _invoice), do: Invoices.company_snapshot(organization)

  defp mount_edit(id, _organization, socket) do
    case Invoices.get_invoice(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That invoice does not exist.")
         |> push_navigate(to: ~p"/invoices")}

      invoice ->
        client = invoice.client_id && Clients.get_client(invoice.client_id)

        {:ok,
         socket
         |> assign(:page_title, "Edit #{invoice.invoice_number}")
         |> assign(:invoice, invoice)
         |> assign(:currency, invoice.currency || QuantumBilling.Currency.default())
         |> assign(:selected_client_id, invoice.client_id)
         |> assign(:gstin_hint, gstin_hint(client))
         |> assign_tax(Invoice.vat?(invoice))
         |> assign_client_options()
         |> assign_form(Invoices.change_invoice(invoice, missing_tax_ids(invoice, client)))}
    end
  end

  # Offers tax ids the client record can supply; saved only if the user saves.
  defp missing_tax_ids(%Invoice{tax_regime: "vat"} = invoice, client) do
    put_missing(%{}, "client_tax_number", invoice.client_tax_number, client && client.tax_number)
  end

  defp missing_tax_ids(%Invoice{} = invoice, client) do
    gstin = present(invoice.client_gstin) || present(client && client.gstin)

    pan =
      present(invoice.client_pan) || present(client && client.pan) || GST.pan_from_gstin(gstin)

    %{}
    |> put_missing("client_gstin", invoice.client_gstin, gstin)
    |> put_missing("client_pan", invoice.client_pan, pan)
  end

  defp put_missing(params, key, stored, found) do
    if present(stored) == nil and found != nil, do: Map.put(params, key, found), else: params
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil

  def handle_event("search_clients", %{"value" => search}, socket) do
    {:noreply, socket |> assign(:client_search, search) |> assign_client_options()}
  end

  def handle_event("validate", %{"invoice" => params} = event, socket) do
    {params, socket} =
      params
      |> match_typed_client(event["_target"])
      |> apply_client_choice(socket)

    params = params |> pan_from_gstin() |> apply_payment_term()

    %{invoice: invoice, organization: organization} = socket.assigns

    changeset =
      invoice
      |> Invoices.change_invoice(params, preview_trusted(organization, invoice))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  # Save Draft and Preview are the same write.
  def handle_event("save", %{"invoice" => params}, socket) do
    {params, _socket} = apply_client_choice(params, socket)
    params = params |> pan_from_gstin() |> apply_payment_term()

    case save_invoice(socket.assigns.invoice, params) do
      {:ok, invoice} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_message(socket.assigns.invoice, invoice))
         |> push_navigate(to: ~p"/invoices/#{invoice.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please fix the highlighted fields.")
         |> assign_form(changeset)}
    end
  end

  defp save_invoice(%Invoice{id: nil}, params), do: Invoices.create_invoice(params)
  defp save_invoice(%Invoice{} = invoice, params), do: Invoices.update_invoice(invoice, params)

  defp saved_message(%Invoice{id: nil}, invoice),
    do: "Invoice #{invoice.invoice_number} saved as a draft."

  defp saved_message(_existing, invoice), do: "Invoice #{invoice.invoice_number} updated."

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    invoice = Ecto.Changeset.apply_changes(changeset)

    socket
    |> assign(:form, to_form(changeset, as: "invoice"))
    |> assign(:summary, invoice)
    |> assign(:intra_state?, Invoice.intra_state?(changeset))
  end

  # Copies the client's details only when the choice changes, so edits survive.
  # The previous choice is kept server-side, not in a hidden input.
  defp apply_client_choice(params, socket) do
    id = params["client_id"]

    # From the database: the client may no longer be in the picker's results.
    client = id not in [nil, ""] && Clients.get_client(id)

    cond do
      client && to_string(id) != to_string(socket.assigns.selected_client_id) ->
        {copy_client(params, client),
         socket
         |> assign(:selected_client_id, id)
         |> assign(:gstin_hint, gstin_hint(client))
         |> assign_client_options()}

      id == "" and socket.assigns.selected_client_id != nil ->
        {params, socket |> assign(:selected_client_id, nil) |> assign(:gstin_hint, nil)}

      true ->
        {params, socket}
    end
  end

  # `client_id` stays a string so the picker comparisons work; the rest is the shared API snapshot.
  defp copy_client(params, client) do
    Map.merge(params, Map.delete(Invoices.client_snapshot(client), "client_id"))
  end

  # A typed name that exactly matches a client selects that client,
  # but only when the name box itself changed.
  defp match_typed_client(params, ["invoice", "client_name"]) do
    case Clients.get_client_by_name(params["client_name"]) do
      nil -> params
      client -> Map.put(params, "client_id", to_string(client.id))
    end
  end

  defp match_typed_client(params, _other_target), do: params

  # Fills an empty PAN from the GSTIN (characters 3-12); never overwrites one.
  defp pan_from_gstin(params) do
    gstin = params |> Map.get("client_gstin") |> to_string() |> String.trim() |> String.upcase()

    case {present(params["client_pan"]), GST.pan_from_gstin(gstin)} do
      {nil, pan} when is_binary(pan) -> Map.put(params, "client_pan", pan)
      _typed_or_no_gstin -> params
    end
  end

  defp gstin_hint(%Clients.Client{} = client) do
    if present(client.gstin) == nil do
      "No GSTIN on file for this client (#{client.client_type})."
    end
  end

  defp gstin_hint(_no_client), do: nil

  defp assign_client_options(socket) do
    options =
      Clients.picker_options(socket.assigns.client_search, socket.assigns.selected_client_id)

    socket
    |> assign(:clients, options)
    |> assign(:client_options_truncated?, length(options) >= Clients.picker_limit())
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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        {@page_title}
        <:actions>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/invoices"} class={secondary_button_class()}>Cancel</.link>
            <button type="submit" form="invoice-form" class={secondary_button_class()}>
              <.icon name="hero-document-text" class="size-4" /> {if @invoice.id,
                do: "Save Changes",
                else: "Save Draft"}
            </button>

            <button type="submit" form="invoice-form" class={action_button_class()}>
              <.icon name="hero-eye" class="size-4" /> Preview Invoice
            </button>
          </div>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 gap-3 lg:grid-cols-3">
        <.form
          :let={f}
          for={@form}
          id="invoice-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-3 lg:col-span-2"
        >
          <.card padding="p-4">
            <div class="mb-3 flex items-center gap-2.5">
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
                1
              </span>

              <h2 class="text-sm font-semibold tracking-tight">Invoice Details</h2>
            </div>

            <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
              <.field
                field={f[:invoice_type]}
                label="Invoice Type"
                type="select"
                required
                options={Invoices.invoice_types()}
              />
              <%!-- Frozen onto the invoice on save, so editable only while a draft. --%>
              <.field
                :if={@template_options != []}
                field={f[:template_id]}
                label="Design"
                type="select"
                options={@template_options}
                disabled={@invoice.status != "Draft"}
                hint={
                  if @invoice.status != "Draft",
                    do: "Locked — this invoice keeps the design it was issued with."
                }
              />
              <div>
                <span class="mb-1.5 block text-xs font-medium text-base-content/60">
                  Invoice No.<span class="ml-0.5 text-error">*</span>
                </span>

                <div class="flex h-9 items-center rounded-field border border-base-300 bg-base-200 px-3 text-sm font-medium">
                  {@invoice.invoice_number || Settings.next_invoice_number(@organization)}
                </div>

                <p class="mt-1 text-2xs text-base-content/45">
                  {if @invoice.id,
                    do: "Fixed once issued — it belongs to the numbering series.",
                    else: "Assigned on save. Change the series in Settings."}
                </p>
              </div>
              <.field field={f[:invoice_date]} label="Invoice Date" type="date" required />
              <.field
                :if={!@vat?}
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
              /> <.field field={f[:due_date]} label="Due Date" type="date" />
            </div>

            <div :if={@vat?} id="invoice-reverse-charge" class="mt-3">
              <.toggle
                field={f[:reverse_charge]}
                label="Reverse charge"
                hint="The customer accounts for the VAT, so none is charged on this invoice."
              />
            </div>

            <.custom_fields_section
              id="invoice-custom-fields"
              form={f}
              definitions={@custom_definitions}
              object="invoice"
              current_scope={@current_scope}
              class="mt-4 border-t border-base-300 pt-4"
            />
          </.card>

          <.card padding="p-4">
            <div class="mb-3 flex items-center gap-2.5">
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
                2
              </span>

              <h2 class="text-sm font-semibold tracking-tight">Client Details</h2>
            </div>

            <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <div>
                <label
                  for={f[:client_id].id}
                  class="mb-1.5 block text-xs font-medium text-base-content/60"
                >
                  Client Name<span class="ml-0.5 text-error">*</span>
                </label>

                <div class="flex gap-2">
                  <div class="flex min-w-0 flex-1 flex-col gap-1.5">
                    <div class="relative">
                      <.icon
                        name="hero-magnifying-glass"
                        class="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-base-content/45"
                      />
                      <%!-- phx-keyup with no name, not a nested form: a nested form would end the invoice form early. --%>
                      <input
                        type="text"
                        id="client-picker-search"
                        value={@client_search}
                        phx-keyup="search_clients"
                        phx-debounce="300"
                        placeholder="Search clients by name, GSTIN or email..."
                        class={filter_input_class()}
                      />
                    </div>

                    <select
                      id={f[:client_id].id}
                      name={f[:client_id].name}
                      class={form_select_class()}
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
                  </div>

                  <.link
                    navigate={~p"/clients/new"}
                    class={[secondary_button_class(), "shrink-0 self-end"]}
                    title="Add a new client"
                  >
                    <.icon name="hero-plus" class="size-4" />
                  </.link>
                </div>

                <p
                  :if={@clients == [] and @client_search == ""}
                  class="mt-1 text-2xs text-base-content/45"
                >
                  No clients yet — add one first, or type the details in below.
                </p>

                <p
                  :if={@clients == [] and @client_search != ""}
                  class="mt-1 text-2xs text-base-content/45"
                >
                  No clients match &ldquo;{@client_search}&rdquo;.
                </p>

                <p :if={@client_options_truncated?} class="mt-1 text-2xs text-base-content/45">
                  Showing the first {Clients.picker_limit()} — search to narrow them down.
                </p>
              </div>

              <.field
                :if={!@vat?}
                field={f[:client_state]}
                label="State"
                type="select"
                prompt="Select state"
                options={EWayBillForm.states()}
              />
              <.field
                :if={@vat?}
                field={f[:client_state]}
                label="Region / Emirate"
                maxlength="80"
              /> <.field field={f[:client_name]} label="Client Name" required />
              <.field
                :if={!@vat?}
                field={f[:client_gstin]}
                label="GSTIN"
                placeholder="27AABCA1234A1Z5"
                hint={if(f[:client_gstin].value in [nil, ""], do: @gstin_hint)}
              />
              <.field
                :if={@vat?}
                field={f[:client_tax_number]}
                label="VAT No. / TRN"
                maxlength="30"
                hint={
                  if f[:reverse_charge].value in [true, "true"],
                    do: "Needed on a reverse-charge invoice."
                }
              />
              <.field
                field={f[:client_billing_address]}
                label="Billing Address"
                type="textarea"
                rows="4"
              />
              <div class="space-y-3">
                <.field
                  :if={!@vat?}
                  field={f[:client_pan]}
                  label="PAN"
                  placeholder="AABCA1234A"
                />
                <.field field={f[:client_email]} label="Email" type="email" />
              </div>
            </div>
          </.card>

          <.card padding="p-4">
            <div class="mb-3 flex items-center gap-2.5">
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
                3
              </span>

              <h2 class="text-sm font-semibold tracking-tight">Item Details</h2>
            </div>

            <div class="overflow-x-auto">
              <table class="w-full">
                <thead>
                  <tr class={table_head_class()}>
                    <th class="w-8 pr-2 text-left">#</th>

                    <th class="pr-2 text-left">
                      Item / Description<span class="ml-0.5 text-error">*</span>
                    </th>

                    <th class="w-28 pr-2 text-left">
                      {if @vat?, do: "Item Code", else: "HSN / SAC"}
                    </th>

                    <th class="w-20 pr-2 text-left">Qty</th>

                    <th class="w-24 pr-2 text-left">Unit</th>

                    <th class="w-28 pr-2 text-left">Rate ({currency_symbol(@currency)})</th>

                    <th class={["pr-2 text-left", if(@vat?, do: "w-36", else: "w-24")]}>
                      {if @vat?, do: "VAT", else: "Tax (%)"}
                    </th>

                    <th class="w-32 pr-2">Amount ({currency_symbol(@currency)})</th>

                    <th class="w-10 text-right">
                      <span class="sr-only">Remove</span>
                    </th>
                  </tr>
                </thead>

                <%!-- inputs_for keeps stored row ids (no duplicate rows on edit); skip_hidden because an input is invalid directly in tbody. --%>
                <tbody id="invoice-items">
                  <.inputs_for :let={item_f} field={f[:items]} skip_hidden>
                    <tr
                      id={"invoice-item-#{item_f.index}"}
                      class={[table_row_class(), @item_definitions != [] && "border-b-0"]}
                    >
                      <td class="py-2 pr-2 align-top text-sm text-base-content/45">
                        {item_f.index + 1}
                      </td>

                      <td class="py-2 pr-2 align-top">
                        <input
                          :for={{name, value} <- item_f.hidden}
                          type="hidden"
                          name={"#{item_f.name}[#{name}]"}
                          value={value}
                        />
                        <input type="hidden" name="invoice[items_sort][]" value={item_f.index} />
                        <input
                          type="hidden"
                          name={item_f[:position].name}
                          value={item_f.index}
                        />
                        <input
                          type="text"
                          id={item_f[:description].id}
                          name={item_f[:description].name}
                          value={item_f[:description].value}
                          placeholder="Item or service"
                          required
                          class={form_input_class()}
                        />
                      </td>

                      <td class="py-2 pr-2 align-top">
                        <input
                          type="text"
                          id={item_f[:hsn_sac].id}
                          name={item_f[:hsn_sac].name}
                          value={item_f[:hsn_sac].value}
                          placeholder={if !@vat?, do: "998313"}
                          class={form_input_class()}
                        />
                      </td>

                      <td class="py-2 pr-2 align-top">
                        <input
                          type="number"
                          min="0.001"
                          step="0.001"
                          id={item_f[:quantity].id}
                          name={item_f[:quantity].name}
                          value={quantity(item_f[:quantity].value)}
                          class={form_input_class()}
                        />
                      </td>

                      <td class="py-2 pr-2 align-top">
                        <select
                          id={item_f[:unit].id}
                          name={item_f[:unit].name}
                          class={form_select_class()}
                        >
                          <option
                            :for={unit <- InvoiceItem.units()}
                            value={unit}
                            selected={item_f[:unit].value == unit}
                          >
                            {unit}
                          </option>
                        </select>
                      </td>

                      <td class="py-2 pr-2 align-top">
                        <input
                          type="number"
                          min="0"
                          step="0.01"
                          id={item_f[:rate].id}
                          name={item_f[:rate].name}
                          value={money_input(item_f[:rate].value)}
                          class={form_input_class()}
                        />
                      </td>

                      <td :if={@vat?} class="py-2 pr-2 align-top">
                        <select
                          id={item_f[:tax_rate_id].id}
                          name={item_f[:tax_rate_id].name}
                          class={[
                            form_select_class(),
                            item_f[:tax_rate_id].errors != [] && form_error_class()
                          ]}
                        >
                          <option :if={@tax_rates == []} value="">Add a rate in Settings</option>
                          <option
                            :for={rate <- @tax_rates}
                            :if={is_nil(rate.archived_at) or selected_rate?(item_f, rate)}
                            value={rate.id}
                            selected={selected_rate?(item_f, rate)}
                          >
                            {TaxRate.label(rate)}{if rate.archived_at, do: " (archived)"}
                          </option>
                        </select>
                        <p
                          :for={{msg, _opts} <- item_f[:tax_rate_id].errors}
                          class="mt-1 text-2xs text-error"
                        >
                          {msg}
                        </p>
                      </td>

                      <td :if={!@vat?} class="py-2 pr-2 align-top">
                        <select
                          id={item_f[:tax_rate].id}
                          name={item_f[:tax_rate].name}
                          class={form_select_class()}
                        >
                          <option
                            :for={rate <- Organization.gst_rates()}
                            value={rate}
                            selected={to_string(item_f[:tax_rate].value) == to_string(rate)}
                          >
                            {rate}%
                          </option>
                        </select>
                      </td>

                      <td class="py-2 pr-2 align-middle">
                        <.line_amount
                          item={item_f.source}
                          invoice={@summary}
                          index={item_f.index}
                          currency={@currency}
                        />
                      </td>

                      <td class="py-2 text-right align-middle">
                        <label
                          id={"invoice-item-remove-#{item_f.index}"}
                          class={[row_action_class(), "ml-auto cursor-pointer"]}
                        >
                          <span class="sr-only">Remove item {item_f.index + 1}</span>
                          <input
                            type="checkbox"
                            name="invoice[items_drop][]"
                            value={item_f.index}
                            class="hidden"
                          /> <.icon name="hero-trash" class="size-4" />
                        </label>
                      </td>
                    </tr>
                    <tr
                      :if={@item_definitions != []}
                      id={"invoice-item-fields-#{item_f.index}"}
                      class={table_row_class()}
                    >
                      <td></td>
                      <td colspan="8" class="pb-3 pr-2">
                        <.custom_inputs
                          form={item_f}
                          definitions={@item_definitions}
                          class="grid grid-cols-2 gap-2 rounded-field bg-base-200/50 p-2.5 sm:grid-cols-4"
                        />
                      </td>
                    </tr>
                  </.inputs_for>
                </tbody>
              </table>
            </div>

            <p
              :for={msg <- item_errors(@form)}
              class="mt-2 flex items-center gap-1 text-2xs text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />{msg}
            </p>

            <label id="invoice-item-add" class={[secondary_button_class(), "mt-4 cursor-pointer"]}>
              <input type="checkbox" name="invoice[items_sort][]" value="new" class="hidden" />
              <.icon name="hero-plus" class="size-4" /> Add New Item
            </label>
          </.card>

          <.card padding="p-4">
            <div class="mb-3 flex items-center gap-2.5">
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
                4
              </span>

              <h2 class="text-sm font-semibold tracking-tight">Additional Information</h2>
            </div>

            <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
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

        <div class="space-y-3 lg:sticky lg:top-16 lg:self-start">
          <.card>
            <h2 class="mb-2.5 text-sm font-semibold tracking-tight">Invoice Summary</h2>

            <div class="space-y-2.5">
              <.summary_line label="Total Items" value={@summary.total_items} />
              <.summary_line label="Total Quantity" value={@summary.total_quantity} />
              <.summary_line
                label="Total Taxable Value"
                value={money(@summary.taxable_value, @currency, decimals: 2, space: true)}
              />
            </div>
            <hr class="my-4 border-base-300" />
            <div :if={@vat?} id="invoice-summary-vat" class="space-y-2.5">
              <.summary_line
                :for={{row, index} <- Enum.with_index(@summary.tax_breakdown || [])}
                id={"invoice-summary-vat-#{index}"}
                label={Tax.breakdown_label(row)}
                value={money(row["tax"], @currency, decimals: 2, space: true)}
              />
              <.summary_line
                id="invoice-summary-vat-total"
                label="Total VAT"
                value={money(@summary.vat_amount, @currency, decimals: 2, space: true)}
              />
            </div>
            <div :if={!@vat?} class="space-y-2.5">
              <.summary_line
                label="CGST"
                value={money(@summary.cgst_amount, @currency, decimals: 2, space: true)}
              />
              <.summary_line
                label="SGST"
                value={money(@summary.sgst_amount, @currency, decimals: 2, space: true)}
              />
              <.summary_line
                label="IGST"
                value={money(@summary.igst_amount, @currency, decimals: 2, space: true)}
              />
              <.summary_line
                label="CESS"
                value={money(@summary.cess_amount, @currency, decimals: 2, space: true)}
              />
            </div>
            <hr :if={!@vat? or @summary.round_to_whole_units} class="my-4 border-base-300" />
            <.summary_line
              :if={!@vat? or @summary.round_to_whole_units}
              id="invoice-summary-round-off"
              label="Round Off"
              value={money(@summary.round_off, @currency, decimals: 2, space: true)}
            />
            <div class="mt-4 flex items-start justify-between gap-3 rounded-field bg-base-200 px-3 py-2.5">
              <span class="text-sm font-semibold">Grand Total</span>
              <span
                id="invoice-summary-grand-total"
                class="text-sm font-semibold tracking-tight tabular-nums"
              >
                {money(@summary.grand_total, @currency, decimals: 2, space: true)}
              </span>
            </div>

            <p class="mt-3 text-2xs uppercase tracking-wider text-base-content/45">
              Amount in Words
            </p>

            <%!-- Two lines reserved, so the card doesn't grow as the total does. --%>
            <p class="mt-1 min-h-[2lh] text-xs text-base-content/60">
              {amount_in_words(@summary.grand_total, @currency)}
            </p>

            <p :if={!@vat?} class="mt-3 text-2xs text-base-content/45">
              {if @intra_state?,
                do: "Same state as your business — CGST and SGST apply.",
                else: "Different state from your business — IGST applies."}
            </p>

            <p :if={@vat?} id="invoice-summary-vat-note" class="mt-3 text-2xs text-base-content/45">
              {vat_note(@summary)}
            </p>
          </.card>

          <.card>
            <div class="flex items-start justify-between gap-3">
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

              <p :if={!@vat? and @organization.gstin} class="text-base-content/60">
                GSTIN: {@organization.gstin}
              </p>

              <p :if={@vat? and @organization.vat_number} class="text-base-content/60">
                VAT No. / TRN: {@organization.vat_number}
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

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp summary_line(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <span class="text-xs text-base-content/60">{@label}</span>
      <span id={@id} class="text-right text-xs font-medium tabular-nums">{@value}</span>
    </div>
    """
  end

  attr :item, Ecto.Changeset, required: true
  attr :invoice, Invoice, required: true
  attr :index, :integer, required: true
  attr :currency, :string, required: true

  defp line_amount(assigns) do
    assigns = assign(assigns, :figures, line_figures(assigns.item, assigns.invoice))

    ~H"""
    <p id={"invoice-item-amount-#{@index}"} class="text-sm font-medium tabular-nums">
      {money(@figures.total, @currency, decimals: 2)}
    </p>

    <p
      id={"invoice-item-tax-#{@index}"}
      class="mt-0.5 whitespace-nowrap text-2xs tabular-nums text-base-content/50"
    >
      incl. {money(@figures.tax, @currency, decimals: 2)} tax
    </p>
    """
  end

  # Same functions as the invoice totals. Under VAT the summary taxes each rate's
  # total once, so a row can differ from it by a fraction of a unit.
  defp line_figures(%Ecto.Changeset{} = changeset, %Invoice{} = invoice) do
    item = Ecto.Changeset.apply_changes(changeset)
    amount = InvoiceItem.amount(item)

    cond do
      not Invoice.vat?(invoice) ->
        tax = InvoiceItem.tax(item)
        %{tax: tax, total: amount + tax}

      invoice.reverse_charge or not is_integer(item.tax_rate_bp) ->
        %{tax: 0, total: amount}

      invoice.prices_include_tax ->
        %{tax: amount - Money.net_of_tax(amount, Tax.effective_bp(item)), total: amount}

      true ->
        tax = InvoiceItem.tax(item)
        %{tax: tax, total: amount + tax}
    end
  end

  defp selected_rate?(item_f, rate),
    do: to_string(item_f[:tax_rate_id].value) == to_string(rate.id)

  defp vat_note(%Invoice{reverse_charge: true}),
    do: "Reverse charge — the customer accounts for the VAT."

  defp vat_note(%Invoice{prices_include_tax: true}), do: "Prices include VAT."
  defp vat_note(_invoice), do: "VAT is added to the prices."

  # The cast_assoc error has no input of its own, so it shows under the table.
  defp item_errors(form) do
    form.source.errors
    |> Keyword.get_values(:items)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end
