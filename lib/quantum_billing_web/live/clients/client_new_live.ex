defmodule QuantumBillingWeb.ClientNewLive do
  @moduledoc """
  The "Add New Client" form.

  Follows the shape of `EWayBillNewLive`: header carrying Cancel and
  Save, then the form. Nothing here needs a running summary the way an invoice
  does, so the form takes the full width and the standing guidance sits behind
  the header's `help_popover/1` rather than in a permanent right-hand rail.

  The GSTIN's required marker follows the client type rather than being fixed —
  an unregistered dealer or a walk-in consumer has no GSTIN, and B2C invoicing
  needs them. `Clients.gstin_required?/1` is the single source of that rule, so
  the asterisk and the changeset can never disagree.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Clients
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.EWayBills.EWayBillForm

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Add New Client")
     |> assign(:active_nav, :clients)
     |> assign_form(Clients.change_client(%Client{}))}
  end

  def handle_event("validate", %{"client" => params}, socket) do
    changeset =
      %Client{}
      |> Clients.change_client(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"client" => params}, socket) do
    case Clients.create_client(params) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{client.name} added.")
         |> push_navigate(to: ~p"/clients")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please fix the highlighted fields.")
         |> assign_form(changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    client_type = Ecto.Changeset.get_field(changeset, :client_type)

    socket
    |> assign(:form, to_form(changeset, as: "client"))
    |> assign(:gstin_required?, Clients.gstin_required?(client_type))
    |> assign(:same_address?, Ecto.Changeset.get_field(changeset, :shipping_same_as_billing))
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        <span class="inline-flex items-center gap-2">
          Add New Client
          <.help_popover id="client-help" label="About adding a client">
            <span class="block">
              <span class="flex items-center gap-2.5">
                <.icon name="hero-information-circle" class="size-4 text-base-content/45" />
                <span class="font-semibold tracking-tight">Information</span>
              </span>

              <span class="mt-3 block text-base-content/60">
                Add accurate client details to create GST invoices, e-way bills and maintain
                compliance.
              </span>
            </span>

            <span class="block">
              <span class="flex items-center gap-2.5">
                <.icon name="hero-light-bulb" class="size-4 text-base-content/45" />
                <span class="font-semibold tracking-tight">Tips</span>
              </span>

              <ul class="mt-3 space-y-2.5">
                <li :for={tip <- tips()} class="flex gap-2 text-base-content/60">
                  <.icon
                    name="hero-check-circle"
                    class="mt-0.5 size-4 shrink-0 text-base-content/45"
                  /> {tip}
                </li>
              </ul>
            </span>
          </.help_popover>
        </span>

        <:actions>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/clients"} class={secondary_button_class()}>Cancel</.link>
            <button type="submit" form="client-form" class={action_button_class()}>
              <.icon name="hero-check" class="size-4" /> Save Client
            </button>
          </div>
        </:actions>
      </.header>

      <div>
        <.form :let={f} for={@form} id="client-form" phx-change="validate" phx-submit="save">
          <.card padding="p-6">
            <h2 class="mb-4 text-sm font-semibold tracking-tight">Basic Information</h2>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
              <.field
                field={f[:client_type]}
                label="Client Type"
                type="select"
                required
                options={Clients.client_types()}
              />
              <.field field={f[:name]} label="Client Name" required placeholder="Enter client name" />
              <.field
                field={f[:display_name]}
                label="Display Name"
                placeholder="Enter display name (optional)"
              />
              <.field
                field={f[:gstin]}
                label="GSTIN"
                required={@gstin_required?}
                placeholder="Enter GSTIN"
                hint={
                  if @gstin_required?,
                    do: "15 characters. The PAN is embedded in it.",
                    else: "Not applicable to this client type."
                }
                disabled={not @gstin_required?}
              /> <.field field={f[:pan]} label="PAN" placeholder="Enter PAN" />
              <.field
                field={f[:legal_name]}
                label="Legal Name"
                placeholder="Enter legal name (if different)"
              />
              <.field
                field={f[:business_type]}
                label="Business Type"
                type="select"
                prompt="Select business type"
                options={Clients.business_types()}
              />
              <.field
                field={f[:category]}
                label="Category"
                type="select"
                prompt="Select category"
                options={Clients.categories()}
              />
            </div>
            <hr class="my-6 border-base-300" />
            <h2 class="mb-4 text-sm font-semibold tracking-tight">Contact Information</h2>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div class="flex gap-2">
                <div class="w-28 shrink-0">
                  <.field
                    field={f[:phone_country_code]}
                    label="Code"
                    type="select"
                    options={Clients.country_codes()}
                  />
                </div>

                <div class="min-w-0 flex-1">
                  <.field
                    field={f[:phone]}
                    label="Phone Number"
                    required
                    placeholder="Enter phone number"
                  />
                </div>
              </div>

              <.field
                field={f[:email]}
                label="Email Address"
                type="email"
                placeholder="Enter email address"
              />
            </div>
            <hr class="my-6 border-base-300" />
            <h2 class="mb-4 text-sm font-semibold tracking-tight">Billing Address</h2>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.field
                field={f[:billing_line1]}
                label="Address Line 1"
                required
                placeholder="Enter address line 1"
              />
              <.field
                field={f[:billing_line2]}
                label="Address Line 2"
                placeholder="Enter address line 2 (optional)"
              />
            </div>

            <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
              <.field field={f[:billing_city]} label="City" required placeholder="Enter city" />
              <.field
                field={f[:billing_state]}
                label="State"
                type="select"
                required
                prompt="Select state"
                options={EWayBillForm.states()}
              />
              <.field
                field={f[:billing_pin]}
                label="PIN Code"
                required
                placeholder="Enter PIN code"
              />
            </div>

            <label class="mt-4 flex w-fit cursor-pointer items-center gap-2 text-sm">
              <input type="hidden" name="client[shipping_same_as_billing]" value="false" />
              <input
                type="checkbox"
                name="client[shipping_same_as_billing]"
                value="true"
                checked={@same_address?}
                class="size-4 accent-base-content"
              /> Same as billing address
            </label>

            <div :if={not @same_address?}>
              <h2 class="mb-4 mt-6 text-sm font-semibold tracking-tight">Shipping Address</h2>

              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.field
                  field={f[:shipping_line1]}
                  label="Address Line 1"
                  placeholder="Enter address line 1"
                />
                <.field
                  field={f[:shipping_line2]}
                  label="Address Line 2"
                  placeholder="Enter address line 2 (optional)"
                />
              </div>

              <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
                <.field field={f[:shipping_city]} label="City" placeholder="Enter city" />
                <.field
                  field={f[:shipping_state]}
                  label="State"
                  type="select"
                  prompt="Select state"
                  options={EWayBillForm.states()}
                />
                <.field
                  field={f[:shipping_pin]}
                  label="PIN Code"
                  placeholder="Enter PIN code"
                />
              </div>
            </div>

            <details class="group mt-6 border-t border-base-300 pt-4">
              <summary class="flex cursor-pointer list-none items-center gap-1.5 text-sm font-semibold tracking-tight">
                Additional Information
                <span class="font-normal text-base-content/45">(Optional)</span>
                <.icon
                  name="hero-chevron-down"
                  class="size-4 text-base-content/45 transition-transform group-open:rotate-180"
                />
              </summary>

              <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
                <.field
                  field={f[:credit_limit]}
                  label="Credit Limit (₹)"
                  type="number"
                  min="0"
                />
                <.field
                  field={f[:payment_terms_days]}
                  label="Payment Terms (days)"
                  type="number"
                  min="0"
                />
                <.field
                  field={f[:opening_balance]}
                  label="Opening Balance (₹)"
                  type="number"
                  min="0"
                />
              </div>

              <div class="mt-4">
                <.field
                  field={f[:notes]}
                  label="Notes"
                  type="textarea"
                  rows="3"
                  placeholder="Anything worth remembering about this client"
                />
              </div>
            </details>
          </.card>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  defp tips do
    [
      "A GSTIN's first two digits are the state code, and must match the billing state.",
      "Unregistered clients and consumers have no GSTIN — leave it blank.",
      "The client email is used for sharing invoices.",
      "Billing and shipping addresses can be the same."
    ]
  end
end
