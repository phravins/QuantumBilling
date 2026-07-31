defmodule QuantumBillingWeb.SettingsLive do
  @moduledoc """
  The Settings page: a section nav down the left, the active section's panel on
  the right.

  The section lives in the URL (`/settings/tax`) rather than in socket state, so
  a panel can be linked to and survives a reload.

  Each panel saves independently through its own section changeset, so filling
  in Tax never trips over a blank field on General. Settings persist to
  `organization_settings` — the first business table in the app.

  Three sections are honestly unbuilt: Users & Roles needs a roles model,
  Backup & Restore needs backup tooling and storage, and Integrations needs
  real third-party credentials. They render a panel saying so rather than
  offering buttons that cannot work.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.SettingsComponents

  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  @saveable ~w(general invoice e_way_bill tax notifications preferences)a

  def mount(_params, _session, socket) do
    if connected?(socket), do: Settings.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:active_nav, :settings)
     |> assign(:organization, Settings.get_organization())}
  end

  # Settings saved in another window. `update_section/3` broadcasts *from* the
  # saver, so this only ever reaches other windows — the one that saved keeps
  # the form it is sitting in.
  #
  # The struct in the message is deliberately ignored and the row re-read. A
  # broadcast is a signal that something changed, not a value to trust: the
  # payload was loaded by a different process, on a different connection, and
  # adopting it wholesale hands this page a record it never read itself. The
  # clients list takes the same approach for the same reason.
  def handle_info({:settings_updated, _organization}, socket) do
    {:noreply,
     socket
     |> assign(:organization, Settings.get_organization())
     |> assign_form(socket.assigns.section)}
  end

  def handle_params(params, _uri, socket) do
    section = section_from(params["section"])

    {:noreply,
     socket
     |> assign(:section, section)
     |> assign_form(section)}
  end

  defp section_from(nil), do: :general

  defp section_from(value) do
    Enum.find_value(sections(), :general, fn s -> if to_string(s.key) == value, do: s.key end)
  end

  defp assign_form(socket, section) when section in @saveable do
    changeset = Settings.change_organization(socket.assigns.organization, %{}, section)
    assign(socket, :form, to_form(changeset, as: "organization"))
  end

  defp assign_form(socket, _section), do: assign(socket, :form, nil)

  def handle_event("validate", %{"organization" => params}, socket) do
    changeset =
      socket.assigns.organization
      |> Settings.change_organization(params, socket.assigns.section)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: "organization"))}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    case Settings.update_section(socket.assigns.organization, params, socket.assigns.section) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(:organization, organization)
         |> assign_form(socket.assigns.section)
         |> put_flash(:info, "#{section(socket.assigns.section).title} saved.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset, as: "organization"))
         |> put_flash(:error, "Please fix the highlighted fields.")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        Settings
        <:subtitle>Manage your account and application settings</:subtitle>
      </.header>

      <div class="grid grid-cols-1 gap-4 lg:grid-cols-12">
        <div class="lg:col-span-4 xl:col-span-3">
          <.section_nav active={@section} />
        </div>

        <div class="space-y-4 lg:col-span-8 xl:col-span-9">
          <.card padding="p-6">
            {render_panel(assigns)}
          </.card>

          <.card :if={@section == :general} padding="p-6">
            <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h2 class="text-sm font-semibold tracking-tight">Logo &amp; Signature</h2>
                <p class="mt-1 text-sm text-base-content/60">
                  Upload your company logo and signature that will appear on invoices.
                </p>
              </div>
              <span class="inline-flex h-9 shrink-0 items-center gap-2 rounded-field border border-base-300 px-3 text-sm text-base-content/45">
                <.icon name="hero-photo" class="size-4" /> Needs file storage
              </span>
            </div>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_panel(%{section: :general} = assigns) do
    ~H"""
    <.panel_header title="General Settings" form_id="settings-form" />

    <.form
      :let={f}
      for={@form}
      id="settings-form"
      phx-change="validate"
      phx-submit="save"
      class="grid grid-cols-1 gap-4 sm:grid-cols-2"
    >
      <.field field={f[:company_name]} label="Company Name" required />
      <.field
        field={f[:gstin]}
        label="GSTIN"
        placeholder="27AABCA1234A1Z5"
        hint="15 characters. The PAN is embedded in it."
      />

      <.field field={f[:trade_name]} label="Trade Name" />
      <.field field={f[:pan]} label="PAN" placeholder="AABCA1234A" />

      <div class="sm:row-span-2">
        <.field field={f[:address]} label="Address" type="textarea" rows="4" />
      </div>
      <.field
        field={f[:state]}
        label="State"
        type="select"
        prompt="Select state"
        options={EWayBillForm.states()}
      />

      <.field field={f[:email]} label="Email Address" type="email" />

      <.field field={f[:phone]} label="Phone Number" placeholder="+91 98765 43210" />
      <.field
        field={f[:financial_year]}
        label="Financial Year"
        type="select"
        prompt="Select financial year"
        options={Settings.financial_years()}
      />

      <.field
        field={f[:currency]}
        label="Currency"
        type="select"
        options={Organization.currencies()}
      />
      <.field
        field={f[:date_format]}
        label="Date Format"
        type="select"
        options={Organization.date_formats()}
      />

      <.field
        field={f[:timezone]}
        label="Time Zone"
        type="select"
        options={Organization.timezones()}
      />
    </.form>
    """
  end

  defp render_panel(%{section: :invoice} = assigns) do
    ~H"""
    <.panel_header title="Invoice Settings" form_id="settings-form" />

    <.form :let={f} for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <.field field={f[:invoice_prefix]} label="Invoice Prefix" required placeholder="INV" />
        <.field field={f[:invoice_next_number]} label="Next Number" type="number" required min="1" />
        <.field
          field={f[:invoice_number_padding]}
          label="Number Padding"
          type="number"
          min="0"
          hint="Leading zeros."
        />
      </div>

      <div class="mt-4 rounded-field border border-base-300 bg-base-200 px-3.5 py-3">
        <p class="text-xs text-base-content/60">Next invoice will be numbered</p>
        <p class="mt-0.5 text-sm font-semibold tracking-tight">
          {Settings.next_invoice_number(Ecto.Changeset.apply_changes(@form.source))}
        </p>
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.field
          field={f[:invoice_due_days]}
          label="Default Payment Terms (days)"
          type="number"
          min="0"
        />
      </div>

      <div class="mt-4">
        <.field
          field={f[:invoice_terms]}
          label="Default Terms & Notes"
          type="textarea"
          rows="4"
          placeholder="Shown at the foot of every invoice"
        />
      </div>
    </.form>
    """
  end

  defp render_panel(%{section: :e_way_bill} = assigns) do
    ~H"""
    <.panel_header title="E-Way Bill Settings" form_id="settings-form" />

    <.form :let={f} for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.field
          field={f[:ewb_transport_mode]}
          label="Default Transport Mode"
          type="select"
          options={EWayBillForm.transport_modes()}
        />
        <.field
          field={f[:ewb_transporter_id]}
          label="Default Transporter ID"
          placeholder="27ABCDE1234F1Z5"
          hint="A 15-character GSTIN. Optional."
        />
        <.field
          field={f[:ewb_threshold_value]}
          label="Threshold Value (₹)"
          type="number"
          min="0"
          hint="An e-way bill is required above this consignment value."
        />
      </div>

      <div class="mt-4">
        <.toggle
          field={f[:ewb_auto_generate]}
          label="Generate an e-way bill automatically"
          hint="When an invoice exceeds the threshold value."
        />
      </div>
    </.form>
    """
  end

  defp render_panel(%{section: :tax} = assigns) do
    ~H"""
    <.panel_header title="Tax Settings" form_id="settings-form" />

    <.form :let={f} for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.field
          field={f[:default_gst_rate]}
          label="Default GST Rate (%)"
          type="select"
          options={Organization.gst_rates()}
          hint="The statutory slabs."
        />
      </div>

      <div class="mt-4 space-y-3">
        <.toggle
          field={f[:cess_enabled]}
          label="Enable cess"
          hint="Adds a cess column to invoices and the tax summary."
        />
        <.toggle
          field={f[:composition_scheme]}
          label="Registered under the composition scheme"
          hint="Files CMP-08 quarterly instead of GSTR-1 and GSTR-3B monthly."
        />
        <.toggle field={f[:tds_enabled]} label="Deduct TDS on applicable invoices" />
      </div>
    </.form>
    """
  end

  defp render_panel(%{section: :notifications} = assigns) do
    ~H"""
    <.panel_header title="Notifications" form_id="settings-form" />

    <.form :let={f} for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <div class="space-y-3">
        <.toggle field={f[:notify_invoice_created]} label="An invoice is created" />
        <.toggle field={f[:notify_ewb_generated]} label="An e-way bill is generated" />
        <.toggle
          field={f[:notify_filing_reminders]}
          label="A GST filing is coming due"
          hint="Uses the compliance calendar."
        />
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.field
          field={f[:reminder_lead_days]}
          label="Remind me this many days ahead"
          type="number"
          min="1"
          max="60"
        />
      </div>
    </.form>
    """
  end

  defp render_panel(%{section: :preferences} = assigns) do
    ~H"""
    <.panel_header title="Preferences" form_id="settings-form" />

    <.form :let={f} for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.field
          field={f[:language]}
          label="Language"
          type="select"
          options={Organization.languages()}
        />
        <.field
          field={f[:rows_per_page]}
          label="Rows Per Page"
          type="select"
          options={Organization.rows_per_page_options()}
        />
      </div>
    </.form>

    <div class="mt-6 border-t border-base-300 pt-5">
      <p class="text-sm font-medium">Theme</p>
      <p class="mt-1 text-sm text-base-content/60">
        Applies immediately and is remembered in this browser, so it is not part of Save Changes.
      </p>
      <div class="mt-3 w-fit">
        <Layouts.theme_toggle />
      </div>
    </div>
    """
  end

  defp render_panel(%{section: :security} = assigns) do
    ~H"""
    <.panel_header title="Security" />

    <dl class="space-y-4">
      <div class="flex items-start justify-between gap-4 border-b border-base-300 pb-4">
        <div>
          <dt class="text-sm font-medium">Email address</dt>
          <dd class="mt-0.5 text-sm text-base-content/60">{@current_scope.user.email}</dd>
        </div>
        <span :if={@current_scope.user.confirmed_at} class="shrink-0">
          <.status_badge status="Active" />
        </span>
      </div>

      <div>
        <dt class="text-sm font-medium">Password</dt>
        <dd class="mt-0.5 text-sm text-base-content/60">
          Changing your email or password asks you to confirm it is you first.
        </dd>
      </div>
    </dl>

    <.link navigate={~p"/users/settings"} class={[action_button_class(), "mt-6"]}>
      <.icon name="hero-lock-closed" class="size-4" /> Manage account security
    </.link>
    """
  end

  defp render_panel(%{section: :users} = assigns) do
    ~H"""
    <.panel_header title="Users & Roles" />
    <.unbuilt_panel
      title="Users & Roles"
      icon="hero-users"
      needs="Inviting teammates and assigning permissions needs a roles model on the users table, which does not exist yet."
    />
    """
  end

  defp render_panel(%{section: :backup} = assigns) do
    ~H"""
    <.panel_header title="Backup & Restore" />
    <.unbuilt_panel
      title="Backup & Restore"
      icon="hero-cloud-arrow-up"
      needs="Exporting and restoring your data needs backup tooling and somewhere durable to store the archives."
    />
    """
  end

  defp render_panel(%{section: :integrations} = assigns) do
    ~H"""
    <.panel_header title="Integrations" />
    <.unbuilt_panel
      title="Integrations"
      icon="hero-squares-2x2"
      needs="Connecting a GST Suvidha Provider, payment gateway or accounting tool needs credentials for those services."
    />
    """
  end
end
