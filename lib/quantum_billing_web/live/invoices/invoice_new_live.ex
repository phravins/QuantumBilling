defmodule QuantumBillingWeb.InvoiceNewLive do
  @moduledoc """
  The invoice form: header actions, the form, and a live summary rail.

  The summary uses `Invoice.recalculate/1`, the same arithmetic that is stored.
  Picking a client, or typing its exact name, copies its details, which stay
  editable. An empty PAN is filled from the GSTIN.

  Under VAT each line picks one of the business's rates, place of supply is not
  asked, and the summary shows a row per rate.

  `?quotation=ID` converts an accepted quotation: the form opens with its
  client and lines, and saving links the invoice to it.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.CustomFieldComponents, only: [custom_fields_section: 1]
  import QuantumBillingWeb.DocumentFormComponents
  import QuantumBillingWeb.SettingsComponents, only: [toggle: 1]

  alias QuantumBilling.Clients
  alias QuantumBilling.CustomFields
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.GST
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Quotations
  alias QuantumBilling.Quotations.Quotation
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.TaxRates
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.DocumentForm

  # Serves both new and edit.
  def mount(params, _session, socket) do
    organization = Settings.get_organization()

    socket =
      socket
      |> assign(:active_nav, :invoices)
      |> assign(:organization, organization)
      |> assign(:custom_definitions, CustomFields.active_definitions("invoice"))
      |> assign(:item_definitions, CustomFields.active_definitions("invoice_item"))
      |> assign(:from_quotation, nil)
      |> DocumentForm.init_client_picker()
      # Read-only: opening the form must not create a design.
      |> assign(:template_options, template_options())

    case params do
      %{"id" => id} -> mount_edit(id, organization, socket)
      %{"quotation" => id} -> mount_from_quotation(id, organization, socket)
      _new -> {:ok, mount_new(organization, socket)}
    end
  end

  # Empty when no design exists; the picker is then hidden.
  defp template_options do
    Enum.map(Templates.list_templates(), fn template -> {template.name, template.id} end)
  end

  defp mount_new(organization, socket, overrides \\ %{}) do
    today = Date.utc_today()

    params =
      Map.merge(
        %{
          "invoice_date" => Date.to_iso8601(today),
          "payment_terms" => default_term(organization),
          "due_date" => Date.to_iso8601(Date.add(today, organization.invoice_due_days || 30)),
          "place_of_supply" => organization.state,
          "terms" => organization.invoice_terms,
          "items" => %{"0" => DocumentForm.blank_item(0)}
        },
        overrides
      )

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

  # Only an Accepted quotation with no invoice yet opens the form; the save
  # checks again under a lock.
  defp mount_from_quotation(id, organization, socket) do
    case Quotations.get_quotation(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That quotation does not exist.")
         |> push_navigate(to: ~p"/quotations")}

      %Quotation{} = quotation ->
        if Quotations.convertible?(quotation) do
          client = quotation.client_id && Clients.get_client(quotation.client_id)
          params = Quotations.invoice_params(quotation)

          socket =
            socket
            |> assign(:from_quotation, quotation)
            |> DocumentForm.init_client_picker(params["client_id"], client)

          {:ok,
           organization |> mount_new(socket, params) |> assign(:currency, quotation.currency)}
        else
          {:ok,
           socket
           |> put_flash(:error, not_convertible_message(quotation))
           |> push_navigate(to: ~p"/quotations/#{quotation.id}")}
        end
    end
  end

  defp not_convertible_message(%Quotation{invoice: %Invoice{invoice_number: number}}),
    do: "This quotation was already converted to #{number}."

  defp not_convertible_message(_quotation),
    do: "Only an accepted quotation can be converted. Accept it first."

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
         |> DocumentForm.init_client_picker(invoice.client_id, client)
         |> assign_tax(Invoice.vat?(invoice))
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

  defp present(value), do: DocumentForm.present(value)

  def handle_event("search_clients", %{"value" => search}, socket) do
    {:noreply, DocumentForm.search_clients(socket, search)}
  end

  def handle_event("validate", %{"invoice" => params} = event, socket) do
    {params, socket} =
      params
      |> DocumentForm.match_typed_client(event["_target"], "invoice")
      |> DocumentForm.apply_client_choice(socket)

    params = params |> DocumentForm.pan_from_gstin() |> apply_payment_term()

    %{invoice: invoice, organization: organization} = socket.assigns

    changeset =
      invoice
      |> Invoices.change_invoice(params, preview_trusted(organization, invoice))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  # Save Draft and Preview are the same write.
  def handle_event("save", %{"invoice" => params}, socket) do
    {params, _socket} = DocumentForm.apply_client_choice(params, socket)
    params = params |> DocumentForm.pan_from_gstin() |> apply_payment_term()

    case save_invoice(socket.assigns.invoice, params, socket) do
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

      {:error, :quotation_not_convertible} ->
        quotation = socket.assigns.from_quotation

        {:noreply,
         socket
         |> put_flash(:error, "This quotation can no longer be converted.")
         |> push_navigate(to: ~p"/quotations/#{quotation.id}")}
    end
  end

  # The quotation comes from the assigns, never from the submitted params.
  defp save_invoice(%Invoice{id: nil}, params, socket) do
    opts =
      case socket.assigns.from_quotation do
        %Quotation{id: id} -> [quotation_id: id, user_id: socket.assigns.current_scope.user.id]
        nil -> []
      end

    Invoices.create_invoice(params, opts)
  end

  defp save_invoice(%Invoice{} = invoice, params, _socket),
    do: Invoices.update_invoice(invoice, params)

  defp saved_message(%Invoice{id: nil}, invoice),
    do: "Invoice #{invoice.invoice_number} saved as a draft."

  defp saved_message(_existing, invoice), do: "Invoice #{invoice.invoice_number} updated."

  defp credit_limit_warning(socket, invoice) do
    with client_id when not is_nil(client_id) <- invoice.client_id,
         client when not is_nil(client) <- Clients.get_client(client_id),
         true <- is_integer(client.credit_limit) and client.credit_limit > 0 do
      outstanding = Clients.outstanding(client)

      previous =
        case socket.assigns.invoice do
          %Invoice{id: id, client_id: ^client_id, grand_total: amount, status: status}
          when not is_nil(id) and status not in ["Paid", "Cancelled"] ->
            amount || 0

          _ ->
            0
        end

      projected = max(outstanding - previous, 0) + (invoice.grand_total || 0)
      currency = invoice.currency || QuantumBilling.Currency.default()

      if Clients.over_credit_limit?(client, projected) do
        "This invoice takes #{client.name} to #{QuantumBillingWeb.Format.money(projected, currency)} outstanding, over their #{QuantumBillingWeb.Format.money(client.credit_limit, currency)} credit limit."
      end
    else
      _ -> nil
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    invoice = Ecto.Changeset.apply_changes(changeset)

    warning = credit_limit_warning(socket, invoice)

    socket
    |> assign(:form, to_form(changeset, as: "invoice"))
    |> assign(:summary, invoice)
    |> assign(:intra_state?, Invoice.intra_state?(changeset))
    |> assign(:credit_limit_warning, warning)
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
            <button
              type="submit"
              phx-disable-with="Saving…"
              form="invoice-form"
              class={secondary_button_class()}
            >
              <.icon name="hero-document-text" class="size-4" /> {if @invoice.id,
                do: "Save Changes",
                else: "Save Draft"}
            </button>

            <button
              type="submit"
              phx-disable-with="Saving…"
              form="invoice-form"
              class={action_button_class()}
            >
              <.icon name="hero-eye" class="size-4" /> Preview Invoice
            </button>
          </div>
        </:actions>
      </.header>

      <div
        :if={@from_quotation}
        id="from-quotation-banner"
        class="mb-3 flex flex-wrap items-center gap-2 rounded-box border border-primary/30 bg-primary/5 px-3.5 py-2.5 text-xs"
      >
        <.icon name="hero-clipboard-document-list" class="size-4 text-primary" />
        <span>
          From quotation
          <.link
            navigate={~p"/quotations/#{@from_quotation.id}"}
            class="font-semibold hover:underline"
          >
            {@from_quotation.number}
          </.link>
          — saving links this invoice to it.
        </span>
      </div>

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

            <div id="invoice-reverse-charge" class="mt-3">
              <.toggle
                field={f[:reverse_charge]}
                label="Reverse charge"
                hint={
                  if @vat?,
                    do: "The customer accounts for the VAT, so none is charged on this invoice.",
                    else:
                      "The buyer pays the GST to the government (Section 9(3) / IGST 5(3)). " <>
                        "The tax is printed but not charged. Needs the buyer's GSTIN."
                }
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

          <.client_section
            form={f}
            vat?={@vat?}
            clients={@clients}
            client_search={@client_search}
            truncated?={@client_options_truncated?}
            gstin_hint={@gstin_hint}
          />

          <.items_section
            form={f}
            vat?={@vat?}
            tax_rates={@tax_rates}
            currency={@currency}
            summary={@summary}
            item_definitions={@item_definitions}
          />

          <div
            :if={@credit_limit_warning}
            role="alert"
            class="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900"
          >
            <.icon name="hero-exclamation-triangle" class="mr-1 inline size-4" />
            {@credit_limit_warning}
          </div>

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
          <.summary_card
            prefix="invoice"
            title="Invoice Summary"
            summary={@summary}
            currency={@currency}
            vat?={@vat?}
            intra_state?={@intra_state?}
          />

          <.company_card organization={@organization} vat?={@vat?} />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
