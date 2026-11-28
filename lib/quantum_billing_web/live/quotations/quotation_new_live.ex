defmodule QuantumBillingWeb.QuotationNewLive do
  @moduledoc """
  The quotation form, for new and edit: the same client picker, lines and
  live tax summary as the invoice form (`DocumentFormComponents`), with a
  validity date in place of payment terms.

  Only a Draft or Sent quotation can be edited; opening an Accepted or
  Declined one goes back to its page.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.DocumentFormComponents
  import QuantumBillingWeb.CustomFieldComponents, only: [custom_fields_section: 1]
  import QuantumBillingWeb.SettingsComponents, only: [toggle: 1]

  alias QuantumBilling.Clients
  alias QuantumBilling.CustomFields
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Quotations
  alias QuantumBilling.Quotations.Quotation
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.TaxRates
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.DocumentForm
  alias QuantumBillingWeb.HsnSuggestions

  def mount(params, _session, socket) do
    organization = Settings.get_organization()

    socket =
      socket
      |> assign(:active_nav, :quotations)
      |> assign(:organization, organization)
      |> assign(:template_options, template_options())
      |> assign(:custom_definitions, CustomFields.active_definitions("quotation"))
      |> assign(:item_definitions, CustomFields.active_definitions("quotation_item"))
      |> DocumentForm.init_client_picker()

    case params do
      %{"id" => id} -> mount_edit(id, socket)
      _new -> {:ok, mount_new(organization, socket)}
    end
  end

  defp template_options do
    Enum.map(Templates.list_templates(), fn template -> {template.name, template.id} end)
  end

  defp mount_new(organization, socket) do
    today = Quotations.today()

    params = %{
      "quotation_date" => Date.to_iso8601(today),
      "valid_until" => Date.to_iso8601(Quotations.default_valid_until(organization, today)),
      "place_of_supply" => organization.state,
      "terms" => organization.invoice_terms,
      "items" => %{"0" => DocumentForm.blank_item(0)}
    }

    quotation = %Quotation{}

    socket
    |> assign(:page_title, "New Quotation")
    |> assign(:quotation, quotation)
    |> assign(:currency, Organization.currency_code(organization))
    |> assign_tax(Organization.vat?(organization))
    |> assign_form(
      Quotations.change_quotation(
        quotation,
        params,
        Quotations.preview_trusted(organization, quotation)
      )
    )
  end

  defp mount_edit(id, socket) do
    case Quotations.get_quotation(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That quotation does not exist.")
         |> push_navigate(to: ~p"/quotations")}

      %Quotation{} = quotation ->
        if Quotation.editable?(quotation) do
          client = quotation.client_id && Clients.get_client(quotation.client_id)

          {:ok,
           socket
           |> assign(:page_title, "Edit #{quotation.number}")
           |> assign(:quotation, quotation)
           |> assign(:currency, quotation.currency || QuantumBilling.Currency.default())
           |> DocumentForm.init_client_picker(quotation.client_id, client)
           |> assign_tax(Quotation.vat?(quotation))
           |> assign_form(Quotations.change_quotation(quotation))}
        else
          {:ok,
           socket
           |> put_flash(
             :error,
             "An #{String.downcase(quotation.status)} quotation can't be edited."
           )
           |> push_navigate(to: ~p"/quotations/#{quotation}")}
        end
    end
  end

  defp assign_tax(socket, vat?) do
    socket
    |> assign(:vat?, vat?)
    |> assign(:tax_rates, if(vat?, do: TaxRates.list_rates(archived: :include), else: []))
    |> HsnSuggestions.init(vat?)
  end

  def handle_event("search_clients", %{"value" => search}, socket) do
    {:noreply, DocumentForm.search_clients(socket, search)}
  end

  def handle_event("validate", %{"quotation" => params} = event, socket) do
    {params, socket} =
      params
      |> DocumentForm.match_typed_client(event["_target"], "quotation")
      |> DocumentForm.apply_client_choice(socket)

    params = DocumentForm.pan_from_gstin(params)

    {:noreply,
     socket
     |> preview(params)
     |> HsnSuggestions.on_change(
       "quotation",
       Map.put(params, "hsn_lookup", event["hsn_lookup"]),
       event["_target"]
     )}
  end

  # HSN/SAC suggestions on the item rows (GST only).
  def handle_event("pick_hsn", %{"index" => index, "code" => code, "rate" => rate}, socket) do
    params = HsnSuggestions.pick_params(socket.assigns.form.params, index, code, rate)

    {:noreply, socket |> preview(params) |> HsnSuggestions.picked(index, code, rate)}
  end

  def handle_event("hsn_lookup_open", %{"index" => index}, socket),
    do: {:noreply, HsnSuggestions.open_lookup(socket, index)}

  def handle_event("close_hsn", _params, socket),
    do: {:noreply, HsnSuggestions.close_all(socket)}

  def handle_event("save", %{"quotation" => params}, socket) do
    {params, _socket} = DocumentForm.apply_client_choice(params, socket)
    params = DocumentForm.pan_from_gstin(params)
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.quotation do
        %Quotation{id: nil} -> Quotations.create_quotation(scope, params)
        quotation -> Quotations.update_quotation(scope, quotation, params)
      end

    case result do
      {:ok, quotation} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_message(socket.assigns.quotation, quotation))
         |> push_navigate(to: ~p"/quotations/#{quotation}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please fix the highlighted fields.")
         |> assign_form(changeset)}

      {:error, :locked} ->
        {:noreply,
         socket
         |> put_flash(:error, "This quotation can no longer be edited.")
         |> push_navigate(to: ~p"/quotations/#{socket.assigns.quotation}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The quotation could not be saved. Try again.")}
    end
  end

  defp saved_message(%Quotation{id: nil}, quotation), do: "Quotation #{quotation.number} saved."

  defp saved_message(%Quotation{status: "Sent"}, quotation),
    do: "Quotation #{quotation.number} revised. Send the updated quotation before the client can answer."

  defp saved_message(_existing, quotation), do: "Quotation #{quotation.number} updated."

  def handle_info({:clear_hsn_notice, index}, socket),
    do: {:noreply, HsnSuggestions.clear_notice(socket, index)}

  # The form as typed, validated for the live summary; nothing is saved.
  defp preview(socket, params) do
    %{quotation: quotation, organization: organization} = socket.assigns

    changeset =
      quotation
      |> Quotations.change_quotation(params, Quotations.preview_trusted(organization, quotation))
      |> Map.put(:action, :validate)

    assign_form(socket, changeset)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:form, to_form(changeset, as: "quotation"))
    |> assign(:summary, Ecto.Changeset.apply_changes(changeset))
    |> assign(:intra_state?, Invoice.intra_state?(changeset))
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
        <span class="text-base-content/60">{@quotation.number || "New"}</span>
      </nav>

      <.header>
        {@page_title}
        <:actions>
          <div class="flex items-center gap-2">
            <.link
              navigate={if @quotation.id, do: ~p"/quotations/#{@quotation}", else: ~p"/quotations"}
              class={secondary_button_class()}
            >
              Cancel
            </.link>
            <button
              id="save-quotation"
              type="submit"
              form="quotation-form"
              phx-disable-with="Saving..."
              class={action_button_class()}
            >
              <.icon name="hero-check" class="size-4" />
              {if @quotation.id, do: "Save Changes", else: "Save Quotation"}
            </button>
          </div>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 gap-3 lg:grid-cols-3">
        <p
          :if={@quotation.status == "Sent"}
          id="sent-quotation-edit-warning"
          role="status"
          class="rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-xs text-warning lg:col-span-3"
        >
          This quotation has already been sent. Saving changes moves it back to Draft; send the updated version before the client can answer.
        </p>

        <.form
          :let={f}
          for={@form}
          id="quotation-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-3 lg:col-span-2"
        >
          <.card padding="p-4">
            <.step_heading step={1} title="Quotation Details" />

            <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
              <div>
                <span class="mb-1.5 block text-xs font-medium text-base-content/60">
                  Quotation No.<span class="ml-0.5 text-error">*</span>
                </span>

                <div
                  id="quotation-number"
                  class="flex h-9 items-center rounded-field border border-base-300 bg-base-200 px-3 text-sm font-medium"
                >
                  {@quotation.number || Settings.next_quotation_number(@organization)}
                </div>

                <p class="mt-1 text-2xs text-base-content/45">
                  {if @quotation.id,
                    do: "Fixed once saved.",
                    else: "Assigned on save. Change the series in Settings."}
                </p>
              </div>
              <.field field={f[:quotation_date]} label="Quotation Date" type="date" required />
              <.field
                field={f[:valid_until]}
                label="Valid Until"
                type="date"
                required
                hint="After this date it shows as Expired until you extend it."
              />
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
                :if={@template_options != []}
                field={f[:template_id]}
                label="Design"
                type="select"
                options={@template_options}
              />
            </div>

            <div id="quotation-reverse-charge" class="mt-3">
              <.toggle
                field={f[:reverse_charge]}
                label="Reverse charge"
                hint={
                  if @vat?,
                    do: "The customer accounts for the VAT, so none is charged.",
                    else:
                      "The buyer pays the GST to the government (Section 9(3) / IGST 5(3)). " <>
                        "The tax is printed but not charged. Needs the buyer's GSTIN."
                }
              />
            </div>

            <.custom_fields_section
              id="quotation-custom-fields"
              form={f}
              definitions={@custom_definitions}
              object="quotation"
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
            hsn={@hsn}
            tax_rates={@tax_rates}
            currency={@currency}
            summary={@summary}
            item_definitions={@item_definitions}
          />

          <.card padding="p-4">
            <.step_heading step={4} title="Additional Information" />

            <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <.field
                field={f[:remarks]}
                label="Remarks"
                type="textarea"
                rows="4"
                placeholder="Scope, delivery time, anything the client should know"
              />
              <.field
                field={f[:terms]}
                label="Terms & Conditions"
                type="textarea"
                rows="4"
                placeholder="Enter terms and conditions (if any)"
              />
            </div>
          </.card>
        </.form>

        <div class="space-y-3 lg:sticky lg:top-16 lg:self-start">
          <.summary_card
            prefix="quotation"
            title="Quotation Summary"
            summary={@summary}
            currency={@currency}
            vat?={@vat?}
            intra_state?={@intra_state?}
          />

          <.company_card organization={@organization} vat?={@vat?} document="quotation" />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
