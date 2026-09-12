defmodule QuantumBillingWeb.SettingsLive do
  @moduledoc """
  The Settings page: a section nav down the left, the active section's panel on
  the right.

  The section lives in the URL (`/settings/tax`) rather than in socket state, so
  a panel can be linked to and survives a reload.

  Each panel saves independently through its own section changeset, so filling
  in Tax never trips over a blank field on General. Settings persist to
  `organization_settings` — the first business table in the app.

  Two sections are honestly unbuilt: Backup & Restore needs backup tooling and
  somewhere durable to put the archives, and Integrations needs real
  third-party credentials. They render a panel saying so rather than offering
  buttons that cannot work.

  Customization is the one panel that is not purely a form: it carries a logo
  upload, so `save` consumes the uploaded entry before handing the params to
  the changeset.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.SettingsComponents
  import QuantumBillingWeb.InvoiceTemplateComponents, only: [template_list: 1]

  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Templates
  alias QuantumBilling.Uploads
  alias QuantumBillingWeb.InvoiceDocument

  @saveable ~w(general invoice e_way_bill tax notifications preferences customization smtp integrations security)a

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Settings.subscribe()
      Templates.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:active_nav, :settings)
     |> assign(:organization, Settings.get_organization())
     # The thumbnails render a real invoice rather than an empty shell, so a
     # design can be judged by how it handles figures and a long description.
     |> assign(:sample, InvoiceDocument.sample())
     |> assign(:templates, [])
     |> allow_upload(:logo,
       accept: Uploads.accepted_extensions(),
       max_entries: 1,
       max_file_size: Uploads.max_bytes()
     )
     |> allow_upload(:backup_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 50_000_000
     )}
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

  # A template edited in the pad, or in another window. Same reasoning as the
  # settings broadcast: re-read rather than adopt the payload.
  def handle_info({:invoice_template_changed, _template}, socket) do
    {:noreply, assign_templates(socket)}
  end

  def handle_params(params, _uri, socket) do
    section = section_from(params["section"])

    {:noreply,
     socket
     |> assign(:section, section)
     |> assign(:page_title, section(section).title)
     |> assign_form(section)
     |> assign_templates(section)}
  end

  # Only the Customization panel lists templates, and `ensure_default/0` writes —
  # so this is called from the one place a user has actually asked to see them,
  # rather than on every settings page load.
  defp assign_templates(socket, :customization) do
    Templates.ensure_default()
    assign_templates(socket)
  end

  defp assign_templates(socket, _section), do: socket

  defp assign_templates(socket) do
    templates =
      Enum.map(Templates.list_templates(), fn template ->
        Map.put(template, :document, Templates.document_of(template))
      end)

    assign(socket, :templates, templates)
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

  # ── Invoice designs ───────────────────────────────────────────────────────
  #
  # These are list actions rather than form fields, so they are plain clicks and
  # do not go through the section's changeset. The design itself is edited in
  # `InvoiceTemplateDesignLive`.

  def handle_event("new_template", _params, socket) do
    case Templates.duplicate_template(Templates.ensure_default()) do
      {:ok, template} ->
        {:noreply, push_navigate(socket, to: ~p"/invoice-templates/#{template.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That design could not be created.")}
    end
  end

  def handle_event("duplicate_template", %{"id" => id}, socket) do
    with_template(socket, id, &Templates.duplicate_template/1, "That design could not be copied.")
  end

  def handle_event("set_default_template", %{"id" => id}, socket) do
    with_template(socket, id, &Templates.set_default/1, "That design could not be made default.")
  end

  def handle_event("delete_template", %{"id" => id}, socket) do
    with_template(socket, id, &Templates.delete_template/1, "That design could not be removed.")
  end

  def handle_event("validate", %{"organization" => params}, socket) do
    changeset =
      socket.assigns.organization
      |> Settings.change_organization(params, socket.assigns.section)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: "organization"))}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    {params, socket} = put_uploaded_logo(params, socket)

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

  def handle_event("remove_logo", _params, socket) do
    organization = socket.assigns.organization
    Uploads.delete(organization.doc_logo_path)

    case Settings.update_section(organization, %{"doc_logo_path" => nil}, :customization) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(:organization, organization)
         |> assign_form(:customization)
         |> put_flash(:info, "Logo removed.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That logo could not be removed.")}
    end
  end

  def handle_event("cancel_logo", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :logo, ref)}
  end

  def handle_event("send_test_email", _params, socket) do
    recipient =
      socket.assigns.current_scope.user.email || socket.assigns.organization.email ||
        "test@example.com"

    sample_invoice = socket.assigns.sample

    case QuantumBilling.InvoiceNotifier.deliver_invoice_pdf(recipient, sample_invoice) do
      {:ok, _email} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Test email with sample PDF successfully dispatched to #{recipient}!"
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to send test email: #{inspect(reason)}")}
    end
  end

  def handle_event("restore_backup", _params, socket) do
    entries =
      consume_uploaded_entries(socket, :backup_file, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case entries do
      [json_content] ->
        case QuantumBilling.Backup.restore_json(json_content) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Database backup successfully restored!")
             |> assign(:organization, Settings.get_organization())}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Restore failed: #{reason}")}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "Please upload a valid JSON backup file first.")}
    end
  end

  # Writes the newly uploaded file, if there is one, and puts its path into the
  # params so the changeset saves it alongside everything else in the panel.
  # Nothing else in the form knows the logo is a file rather than a field.
  # Runs a template action by id, refreshing the list either way. An id the list
  # no longer holds — a stale click from a window opened before it was removed —
  # is a no-op that re-reads rather than an error.
  defp with_template(socket, id, fun, message) do
    case Templates.get_template(id) do
      nil ->
        {:noreply, assign_templates(socket)}

      template ->
        case fun.(template) do
          {:ok, _template} -> {:noreply, assign_templates(socket)}
          {:error, _reason} -> {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  defp put_uploaded_logo(params, socket) do
    previous = socket.assigns.organization.doc_logo_path

    case consume_uploaded_entries(socket, :logo, &store_logo/2) do
      [{:ok, path}] ->
        # The old file is only unlinked once the new one is safely on disk.
        if previous && previous != path, do: Uploads.delete(previous)
        {Map.put(params, "doc_logo_path", path), socket}

      [{:error, message}] ->
        {params, put_flash(socket, :error, "The logo #{message}.")}

      [] ->
        {params, socket}
    end
  end

  defp store_logo(%{path: path}, entry) do
    {:ok, Uploads.store(path, entry.client_type)}
  end

  # LiveView rejects a file before it ever reaches `Uploads.store/2`, so these
  # have to be worded here rather than by the context.
  defp upload_message(:too_large) do
    "That file is larger than #{div(Uploads.max_bytes(), 1_000_000)}MB."
  end

  defp upload_message(:not_accepted), do: "That has to be a PNG, JPEG, GIF, WebP or SVG image."
  defp upload_message(:too_many_files), do: "One logo at a time."
  defp upload_message(other), do: "That file could not be uploaded (#{inspect(other)})."

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      active_sub={@section}
    >
      <%!-- The open section names the page. A standing "Settings / Manage your
      account and application settings" said nothing the sidebar had not
      already said, and left the panel repeating the section title inside its
      own card. Save sits here for the same reason it does on every other form
      page: it belongs to the page, not to the panel. --%>
      <.header>
        {section(@section).title}
        <:actions :if={@form}>
          <button type="submit" form="settings-form" class={action_button_class()}>
            <.icon name="hero-check" class="size-4" /> Save Changes
          </button>
        </:actions>
      </.header>

      <%!-- `gap-4` rather than `space-y-4`: this is a flex column now, so the
      panel can take the height left over instead of stopping under its last
      field. The Logo card below it keeps its natural height. --%>
      <div class="flex flex-1 flex-col gap-4">
        <.card padding="p-6" class="flex flex-1 flex-col">
          {render_panel(assigns)}
        </.card>

        <%!-- The logo moved to Customization, where it sits beside the preview
        that shows what it will look like. This card points at it rather than
        offering a second upload that would fight the first over the same
        column. --%>
        <.card :if={@section == :general} padding="p-6">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="text-sm font-semibold tracking-tight">Logo &amp; Signature</h2>

              <p class="mt-1 text-sm text-base-content/60">
                Your logo, colours and the fields your invoices show live in Customization.
              </p>
            </div>

            <.link navigate={~p"/settings/customization"} class={secondary_button_class()}>
              <.icon name="hero-paint-brush" class="size-4" /> Customization
            </.link>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp render_panel(%{section: :general} = assigns) do
    ~H"""
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
      /> <.field field={f[:trade_name]} label="Trade Name" />
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
      <%!-- Beside the address rather than inside it: the e-invoice export needs
      the city and the PIN as their own fields. --%>
      <.field field={f[:city]} label="City" placeholder="Mumbai" />
      <.field
        field={f[:pincode]}
        label="PIN Code"
        placeholder="400001"
        hint="Needed for the e-invoice export."
      /> <.field field={f[:email]} label="Email Address" type="email" />
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
        /> <.toggle field={f[:tds_enabled]} label="Deduct TDS on applicable invoices" />
      </div>
    </.form>
    """
  end

  defp render_panel(%{section: :notifications} = assigns) do
    ~H"""
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

    <div class="mt-6 border-t border-base-300 pt-5">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h3 class="text-sm font-semibold tracking-tight">SMTP Mailer Test</h3>
          <p class="mt-1 text-xs text-base-content/60">
            Send a sample invoice PDF email to test your SMTP server configuration.
          </p>
        </div>

        <button
          type="button"
          phx-click="send_test_email"
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-semibold shadow-sm transition"
        >
          <.icon name="hero-paper-airplane" class="size-4" /> Send Test Email
        </button>
      </div>
    </div>
    """
  end

  defp render_panel(%{section: :preferences} = assigns) do
    ~H"""
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
    <div class="space-y-6">
      <.form
        :let={f}
        for={@form}
        id="settings-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.field
            field={f[:allowed_ips]}
            label="Allowed IP Ranges (Whitelisting)"
            placeholder="e.g. 192.168.1.0/24, 10.0.0.1"
            hint="Comma-separated IPv4/IPv6 CIDRs. Leave blank to allow all IPs."
          />
          <.field
            field={f[:session_timeout_minutes]}
            label="Session Timeout (Minutes)"
            type="number"
            min="5"
            max="1440"
          />
          <.field
            field={f[:audit_retention_days]}
            label="Audit Log Retention (Days)"
            type="number"
            min="7"
            max="3650"
          />
        </div>

        <.toggle
          field={f[:enforce_2fa]}
          label="Enforce 2FA for all organization users"
          hint="Requires two-factor authentication on every login."
        />
      </.form>

      <hr class="border-base-300" />

      <dl class="space-y-4">
        <div class="flex items-start justify-between gap-4 border-b border-base-300 pb-4">
          <div>
            <dt class="text-sm font-medium">Account Email</dt>
            <dd class="mt-0.5 text-sm text-base-content/60">{@current_scope.user.email}</dd>
          </div>

          <span :if={@current_scope.user.confirmed_at} class="shrink-0">
            <.status_badge status="Active" />
          </span>
        </div>

        <div>
          <dt class="text-sm font-medium">Account Security & Credentials</dt>
          <dd class="mt-0.5 text-sm text-base-content/60">
            Update your email, password, TOTP 2FA keys, and recovery codes.
          </dd>
        </div>
      </dl>

      <.link navigate={~p"/users/settings"} class={secondary_button_class()}>
        <.icon name="hero-lock-closed" class="size-4" /> Account Security Page
      </.link>
    </div>
    """
  end

  defp render_panel(%{section: :smtp} = assigns) do
    ~H"""
    <.form :let={f} for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.field field={f[:smtp_host]} label="SMTP Server Host" placeholder="smtp.mailgun.org" />
        <.field field={f[:smtp_port]} label="Port" type="number" placeholder="587" />
        <.field
          field={f[:smtp_username]}
          label="SMTP Username"
          placeholder="postmaster@yourdomain.com"
        />
        <.field
          field={f[:smtp_password]}
          label="SMTP Password"
          type="password"
          placeholder="••••••••••••"
        />
        <.field field={f[:smtp_from_name]} label="Sender Name" placeholder="QuantumBilling Invoicing" />
        <.field
          field={f[:smtp_from_email]}
          label="Sender Email"
          type="email"
          placeholder="billing@yourcompany.com"
        />
      </div>

      <div class="mt-4">
        <.toggle
          field={f[:smtp_ssl]}
          label="Use SSL / TLS Connection"
          hint="Enable for port 465 (SSL) or STARTTLS on port 587."
        />
      </div>
    </.form>

    <div class="mt-6 border-t border-base-300 pt-5">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h3 class="text-sm font-semibold tracking-tight">Test SMTP Mail Dispatch</h3>
          <p class="mt-1 text-xs text-base-content/60">
            Dispatch a test invoice PDF email using your configured SMTP settings.
          </p>
        </div>

        <button
          type="button"
          phx-click="send_test_email"
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-semibold shadow-sm transition"
        >
          <.icon name="hero-paper-airplane" class="size-4" /> Send Test Email
        </button>
      </div>
    </div>
    """
  end

  defp render_panel(%{section: :customization} = assigns) do
    ~H"""
    <div class="space-y-6">
      <.form :let={f} for={@form} id="settings-form" phx-change="validate" phx-submit="save">
        <h3 class="text-sm font-semibold tracking-tight">Logo</h3>

        <p class="mt-1 text-sm text-base-content/60">
          Used by every template. Falls back to the QuantumBilling mark while empty.
        </p>
        <input type="hidden" name={f[:doc_logo_path].name} value={f[:doc_logo_path].value} />
        <div class="mt-3 flex flex-wrap items-center gap-3">
          <span
            :if={@organization.doc_logo_path}
            class="flex h-12 w-28 items-center justify-center rounded-field border border-base-300 bg-base-100 p-1"
          >
            <img src={@organization.doc_logo_path} alt="Current logo" class="max-h-10 max-w-full" />
          </span>

          <label class={[secondary_button_class(), "cursor-pointer"]}>
            <.icon name="hero-arrow-up-tray" class="size-4" /> {if @organization.doc_logo_path,
              do: "Replace",
              else: "Upload"} <.live_file_input upload={@uploads.logo} class="hidden" />
          </label>

          <button
            :if={@organization.doc_logo_path}
            type="button"
            phx-click="remove_logo"
            class={secondary_button_class()}
          >
            <.icon name="hero-trash" class="size-4" /> Remove
          </button>
        </div>

        <p class="mt-1 text-2xs text-base-content/45">
          PNG, JPEG, GIF, WebP or SVG, up to {div(Uploads.max_bytes(), 1_000_000)}MB.
        </p>

        <div :for={entry <- @uploads.logo.entries} class="mt-2 flex items-center gap-2 text-xs">
          <span class="truncate text-base-content/60">{entry.client_name}</span>
          <span class="text-base-content/45">{entry.progress}%</span>
          <button
            type="button"
            phx-click="cancel_logo"
            phx-value-ref={entry.ref}
            class="text-error hover:underline"
          >
            Cancel
          </button>
        </div>

        <p
          :for={error <- upload_errors(@uploads.logo)}
          class="mt-1 flex items-center gap-1 text-2xs text-error"
        >
          <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />{upload_message(error)}
        </p>
      </.form>
      <hr class="border-base-300" />
      <div>
        <div class="mb-3 flex items-center justify-between gap-3">
          <div>
            <h3 class="text-sm font-semibold tracking-tight">Invoice designs</h3>

            <p class="mt-1 text-sm text-base-content/60">
              Build your own layout block by block. New invoices use the default;
              an invoice keeps the design it was issued with.
            </p>
          </div>

          <button type="button" phx-click="new_template" class={action_button_class()}>
            <.icon name="hero-plus" class="size-4" /> New design
          </button>
        </div>

        <.template_list templates={@templates} invoice={@sample} logo={@organization.doc_logo_path} />
      </div>
    </div>
    """
  end

  defp render_panel(%{section: :backup} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h3 class="text-sm font-semibold tracking-tight">1-Click Full System Backup</h3>
        <p class="mt-1 text-sm text-base-content/60">
          Export and download a complete JSON archive containing all organization settings, clients, invoices, recurring schedules, credit notes, and audit logs.
        </p>

        <div class="mt-4">
          <.link
            href={~p"/settings/backup/download"}
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-semibold shadow transition"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Export & Download JSON Backup
          </.link>
        </div>
      </div>

      <hr class="border-base-300" />

      <div>
        <h3 class="text-sm font-semibold tracking-tight">Restore Database from Backup</h3>
        <p class="mt-1 text-sm text-base-content/60">
          Upload a previously generated QuantumBilling JSON backup file to restore system state.
        </p>

        <form id="restore-form" phx-submit="restore_backup" class="mt-4 space-y-3">
          <div class="flex items-center gap-3">
            <label class={[secondary_button_class(), "cursor-pointer"]}>
              <.icon name="hero-arrow-up-tray" class="size-4" /> Choose Backup File
              <.live_file_input upload={@uploads.backup_file} class="hidden" />
            </label>

            <div :for={entry <- @uploads.backup_file.entries} class="flex items-center gap-2 text-xs">
              <span class="font-mono text-base-content">{entry.client_name}</span>
              <span class="text-base-content/45">({div(entry.client_size, 1024)} KB)</span>
            </div>
          </div>

          <p :for={error <- upload_errors(@uploads.backup_file)} class="text-xs text-error">
            {inspect(error)}
          </p>

          <button
            type="submit"
            disabled={@uploads.backup_file.entries == []}
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-700 disabled:opacity-50 text-white text-sm font-semibold shadow transition"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Execute Restore
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp render_panel(%{section: :integrations} = assigns) do
    ~H"""
    <.form
      :let={f}
      for={@form}
      id="settings-form"
      phx-change="validate"
      phx-submit="save"
      class="space-y-6"
    >
      <div>
        <h3 class="text-sm font-semibold tracking-tight">Razorpay / UPI Payment Gateway</h3>
        <p class="mt-1 text-xs text-base-content/60">
          Enter your live or sandbox API key credentials for automatic invoice payment link generation.
        </p>

        <div class="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.field field={f[:razorpay_key_id]} label="Razorpay Key ID" placeholder="rzp_live_..." />
          <.field
            field={f[:razorpay_key_secret]}
            label="Razorpay Key Secret"
            type="password"
            placeholder="••••••••••••"
          />
        </div>
      </div>

      <hr class="border-base-300" />

      <div>
        <h3 class="text-sm font-semibold tracking-tight">Government IRP / NIC E-Invoice API</h3>
        <p class="mt-1 text-xs text-base-content/60">
          Configure direct IRP / ClearTax API credentials for 1-click IRN & Signed QR code fetching.
        </p>

        <div class="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.field field={f[:irp_username]} label="IRP Username" placeholder="GSTIN_USER" />
          <.field
            field={f[:irp_password]}
            label="IRP Password"
            type="password"
            placeholder="••••••••••••"
          />
          <.field field={f[:irp_client_id]} label="GSP Client ID" placeholder="GSP_CLIENT_..." />
        </div>
      </div>

      <hr class="border-base-300" />

      <div>
        <h3 class="text-sm font-semibold tracking-tight">Custom Event Webhooks</h3>
        <p class="mt-1 text-xs text-base-content/60">
          Stream realtime webhooks on invoice creation, payment completion, e-invoicing, and e-way bill events.
        </p>

        <div class="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.field
            field={f[:webhook_url]}
            label="Webhook Payload Endpoint URL"
            placeholder="https://api.yourcompany.com/webhooks"
          />
          <.field
            field={f[:webhook_secret]}
            label="Webhook Signing Secret (HMAC SHA256)"
            type="password"
            placeholder="whsec_..."
          />
        </div>
      </div>
    </.form>
    """
  end
end
