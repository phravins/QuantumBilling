defmodule QuantumBillingWeb.DocumentFormComponents do
  @moduledoc """
  The form sections an invoice and a quotation share: client, lines, the live
  summary and the issuing company.

  `name` is the form's param name (`"invoice"` or `"quotation"`) and prefixes
  every DOM id, so the invoice form keeps its ids (`invoice-items`,
  `invoice-item-0`, `invoice-summary-grand-total`, ...).

  The summary is the changeset applied (`Invoice.recalculate/1` has run), so
  it shows exactly what will be stored.
  """
  use Phoenix.Component
  use QuantumBillingWeb, :verified_routes

  import QuantumBillingWeb.CoreComponents
  import QuantumBillingWeb.SharedComponents
  import QuantumBillingWeb.Format
  import QuantumBillingWeb.CustomFieldComponents, only: [custom_inputs: 1]

  alias QuantumBilling.Clients
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Money
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Tax
  alias QuantumBilling.TaxRates.TaxRate

  attr :step, :integer, required: true
  attr :title, :string, required: true

  @doc "A numbered card heading."
  def step_heading(assigns) do
    ~H"""
    <div class="mb-3 flex items-center gap-2.5">
      <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
        {@step}
      </span>

      <h2 class="text-sm font-semibold tracking-tight">{@title}</h2>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :step, :integer, default: 2
  attr :vat?, :boolean, required: true
  attr :clients, :list, required: true
  attr :client_search, :string, required: true
  attr :truncated?, :boolean, required: true
  attr :gstin_hint, :string, default: nil

  @doc "Card: the client picker and the client details the document records."
  def client_section(assigns) do
    ~H"""
    <.card padding="p-4">
      <.step_heading step={@step} title="Client Details" />

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div>
          <label
            for={@form[:client_id].id}
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
                <%!-- phx-keyup with no name, not a nested form: a nested form would end the document form early. --%>
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
                id={@form[:client_id].id}
                name={@form[:client_id].name}
                class={form_select_class()}
              >
                <option value="">Select a client</option>

                <option
                  :for={client <- @clients}
                  value={client.id}
                  selected={to_string(@form[:client_id].value) == to_string(client.id)}
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

          <p :if={@clients == [] and @client_search == ""} class="mt-1 text-2xs text-base-content/45">
            No clients yet — add one first, or type the details in below.
          </p>

          <p :if={@clients == [] and @client_search != ""} class="mt-1 text-2xs text-base-content/45">
            No clients match &ldquo;{@client_search}&rdquo;.
          </p>

          <p :if={@truncated?} class="mt-1 text-2xs text-base-content/45">
            Showing the first {Clients.picker_limit()} — search to narrow them down.
          </p>
        </div>

        <.field
          :if={!@vat?}
          field={@form[:client_state]}
          label="State"
          type="select"
          prompt="Select state"
          options={EWayBillForm.states()}
        />
        <.field
          :if={@vat?}
          field={@form[:client_state]}
          label="Region / Emirate"
          maxlength="80"
        /> <.field field={@form[:client_name]} label="Client Name" required />
        <.field
          :if={!@vat?}
          field={@form[:client_gstin]}
          label="GSTIN"
          placeholder="27AABCA1234A1Z5"
          hint={if(@form[:client_gstin].value in [nil, ""], do: @gstin_hint)}
        />
        <.field
          :if={@vat?}
          field={@form[:client_tax_number]}
          label="VAT No. / TRN"
          maxlength="30"
          hint={
            if @form[:reverse_charge].value in [true, "true"],
              do: "Needed on a reverse-charge #{@form.name}."
          }
        />
        <.field
          field={@form[:client_billing_address]}
          label="Billing Address"
          type="textarea"
          rows="4"
        />
        <div class="space-y-3">
          <.field
            :if={!@vat?}
            field={@form[:client_pan]}
            label="PAN"
            placeholder="AABCA1234A"
          />
          <.field field={@form[:client_email]} label="Email" type="email" />
        </div>
      </div>
    </.card>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :step, :integer, default: 3
  attr :vat?, :boolean, required: true
  attr :tax_rates, :list, required: true
  attr :currency, :string, required: true
  attr :summary, :map, required: true, doc: "the applied changeset, for line figures"
  attr :item_definitions, :list, default: []

  @doc "Card: the lines, with add, remove and a live amount per line."
  def items_section(assigns) do
    ~H"""
    <.card padding="p-4">
      <.step_heading step={@step} title="Item Details" />

      <div class="overflow-x-auto">
        <table class="w-full">
          <thead>
            <tr class={table_head_class()}>
              <th class="w-12 pr-2 text-left">S.No</th>

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
          <tbody id={"#{@form.name}-items"}>
            <.inputs_for :let={item_f} field={@form[:items]} skip_hidden>
              <tr
                id={"#{@form.name}-item-#{item_f.index}"}
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
                  <input type="hidden" name={"#{@form.name}[items_sort][]"} value={item_f.index} />
                  <input type="hidden" name={item_f[:position].name} value={item_f.index} />
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
                  <select id={item_f[:unit].id} name={item_f[:unit].name} class={form_select_class()}>
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
                    step={QuantumBilling.Currency.step(@currency)}
                    id={item_f[:rate].id}
                    name={item_f[:rate].name}
                    value={money_input(item_f[:rate].value, @currency)}
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
                    prefix={@form.name}
                    item={item_f.source}
                    summary={@summary}
                    index={item_f.index}
                    currency={@currency}
                  />
                </td>

                <td class="py-2 text-right align-middle">
                  <label
                    id={"#{@form.name}-item-remove-#{item_f.index}"}
                    class={[row_action_class(), "ml-auto cursor-pointer"]}
                  >
                    <span class="sr-only">Remove item {item_f.index + 1}</span>
                    <input
                      type="checkbox"
                      name={"#{@form.name}[items_drop][]"}
                      value={item_f.index}
                      class="hidden"
                    /> <.icon name="hero-trash" class="size-4" />
                  </label>
                </td>
              </tr>
              <tr
                :if={@item_definitions != []}
                id={"#{@form.name}-item-fields-#{item_f.index}"}
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

      <p :for={msg <- item_errors(@form)} class="mt-2 flex items-center gap-1 text-2xs text-error">
        <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />{msg}
      </p>

      <label id={"#{@form.name}-item-add"} class={[secondary_button_class(), "mt-4 cursor-pointer"]}>
        <input type="checkbox" name={"#{@form.name}[items_sort][]"} value="new" class="hidden" />
        <.icon name="hero-plus" class="size-4" /> Add New Item
      </label>
    </.card>
    """
  end

  attr :prefix, :string, required: true
  attr :title, :string, required: true
  attr :summary, :map, required: true
  attr :currency, :string, required: true
  attr :vat?, :boolean, required: true
  attr :intra_state?, :boolean, required: true

  @doc "Card: the document's totals as they will be stored."
  def summary_card(assigns) do
    ~H"""
    <.card>
      <h2 class="mb-2.5 text-sm font-semibold tracking-tight">{@title}</h2>

      <div class="space-y-2.5">
        <.summary_line label="Total Items" value={@summary.total_items} />
        <.summary_line label="Total Quantity" value={@summary.total_quantity} />
        <.summary_line
          label="Total Taxable Value"
          value={money(@summary.taxable_value, @currency, decimals: 2, space: true)}
        />
      </div>
      <hr class="my-4 border-base-300" />
      <div :if={@vat?} id={"#{@prefix}-summary-vat"} class="space-y-2.5">
        <.summary_line
          :for={{row, index} <- Enum.with_index(@summary.tax_breakdown || [])}
          id={"#{@prefix}-summary-vat-#{index}"}
          label={Tax.breakdown_label(row)}
          value={money(row["tax"], @currency, decimals: 2, space: true)}
        />
        <.summary_line
          id={"#{@prefix}-summary-vat-total"}
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
        id={"#{@prefix}-summary-round-off"}
        label="Round Off"
        value={money(@summary.round_off, @currency, decimals: 2, space: true)}
      />
      <div class="mt-4 flex items-start justify-between gap-3 rounded-field bg-base-200 px-3 py-2.5">
        <span class="text-sm font-semibold">Grand Total</span>
        <span
          id={"#{@prefix}-summary-grand-total"}
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

      <p :if={@vat?} id={"#{@prefix}-summary-vat-note"} class="mt-3 text-2xs text-base-content/45">
        {vat_note(@summary)}
      </p>
    </.card>
    """
  end

  attr :organization, :map, required: true
  attr :vat?, :boolean, required: true
  attr :document, :string, default: "invoice"

  @doc "Card: the issuing company, as Settings holds it."
  def company_card(assigns) do
    ~H"""
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
        every {@document}.
      </p>
    </.card>
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

  attr :prefix, :string, required: true
  attr :item, Ecto.Changeset, required: true
  attr :summary, :map, required: true
  attr :index, :integer, required: true
  attr :currency, :string, required: true

  defp line_amount(assigns) do
    assigns = assign(assigns, :figures, line_figures(assigns.item, assigns.summary))

    ~H"""
    <p id={"#{@prefix}-item-amount-#{@index}"} class="text-sm font-medium tabular-nums">
      {money(@figures.total, @currency, decimals: 2)}
    </p>

    <p
      id={"#{@prefix}-item-tax-#{@index}"}
      class="mt-0.5 whitespace-nowrap text-2xs tabular-nums text-base-content/50"
    >
      incl. {money(@figures.tax, @currency, decimals: 2)} tax
    </p>
    """
  end

  # Same functions as the stored totals. Under VAT the summary taxes each rate's
  # total once, so a row can differ from it by a fraction of a unit.
  defp line_figures(%Ecto.Changeset{} = changeset, summary) do
    item = Ecto.Changeset.apply_changes(changeset)
    amount = InvoiceItem.amount(item)

    cond do
      summary.tax_regime != "vat" ->
        tax = InvoiceItem.tax(item)
        %{tax: tax, total: amount + tax}

      summary.reverse_charge or not is_integer(item.tax_rate_bp) ->
        %{tax: 0, total: amount}

      summary.prices_include_tax ->
        %{tax: amount - Money.net_of_tax(amount, Tax.effective_bp(item)), total: amount}

      true ->
        tax = InvoiceItem.tax(item)
        %{tax: tax, total: amount + tax}
    end
  end

  defp selected_rate?(item_f, rate),
    do: to_string(item_f[:tax_rate_id].value) == to_string(rate.id)

  defp vat_note(%{reverse_charge: true}),
    do: "Reverse charge — the customer accounts for the VAT."

  defp vat_note(%{prices_include_tax: true}), do: "Prices include VAT."
  defp vat_note(_document), do: "VAT is added to the prices."

  # The cast_assoc error has no input of its own, so it shows under the table.
  defp item_errors(form) do
    form.source.errors
    |> Keyword.get_values(:items)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end
