defmodule QuantumBillingWeb.SettingsLive do
  @moduledoc """
  The Settings page: a section nav down the left, the active section's panel on
  the right.

  The section lives in the URL (`/settings/tax`) rather than in socket state, so
  a panel can be linked to and survives a reload.

  Each panel saves independently through its own section changeset, so filling
  in Tax never trips over a blank field on General. Settings persist to
  `organization_settings` — the first business table in the app.

  Integrations shows which government portal mode is in use and connects the
  calendars that compliance deadlines are sent to, through `Calendars`.

  Customization is the one panel that is not purely a form: it carries a logo
  upload, so `save` consumes the uploaded entry before handing the params to
  the changeset.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.CalendarComponents, only: [calendar_cards: 1]
  import QuantumBillingWeb.SettingsComponents
  import QuantumBillingWeb.SceneBanner, only: [scene_banner: 1]
  import QuantumBillingWeb.InvoiceTemplateComponents, only: [template_list: 1]

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Calendars
  alias QuantumBilling.Calendars.GoogleClient
  alias QuantumBilling.EInvoice.IRPClient
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.Mail
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Templates
  alias QuantumBilling.Uploads
  alias QuantumBilling.DesignAssets
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoiceDoc.Renderer
  alias QuantumBillingWeb.InvoiceDocument
  alias QuantumBillingWeb.InvoicePdfGenerator

  @saveable ~w(general invoice e_way_bill tax notifications preferences customization smtp integrations security)a

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Settings.subscribe()
      Templates.subscribe()
      Mail.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:active_nav, :settings)
     |> assign_organization(Settings.get_organization())
     |> assign(:deliveries, [])
     |> assign(:templates, [])
     |> assign(:open_tools, nil)
     |> allow_upload(:logo,
       accept: Uploads.accepted_extensions(),
       max_entries: 1,
       max_file_size: Uploads.max_bytes()
     )
     |> allow_upload(:backup_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 50_000_000
     )
     |> assign(:gallery_open, false)
     |> assign(:import_open, false)
     |> assign(:import_error, nil)
     # Both act as soon as the file is in: there is no form to submit.
     |> allow_upload(:design_file,
       accept: ~w(.xml),
       max_entries: 1,
       max_file_size: Templates.max_import_bytes(),
       auto_upload: true,
       progress: &handle_import_progress/3
     )
     |> allow_upload(:letterhead,
       accept: ~w(.png .jpg .jpeg),
       max_entries: 1,
       max_file_size: Uploads.max_bytes(),
       auto_upload: true,
       progress: &handle_import_progress/3
     )}
  end

  # Only other windows get this. Re-read rather than trusting the payload.
  def handle_info({:settings_updated, _organization}, socket) do
    {:noreply,
     socket
     |> assign_organization(Settings.get_organization())
     |> assign_form(socket.assigns.section)}
  end

  def handle_info({:invoice_template_changed, _template}, socket) do
    {:noreply, assign_templates(socket)}
  end

  def handle_info({:email_delivery_changed, _delivery}, socket) do
    if socket.assigns[:section] == :smtp do
      {:noreply, assign_deliveries(socket)}
    else
      {:noreply, socket}
    end
  end

  # Anything else — a broadcast for another page, a library's reply — is not
  # this page's business, and must not take it down.
  def handle_info(_message, socket), do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    section = section_from(params["section"])

    if owner_only?(section) and not Scope.owner?(socket.assigns.current_scope) do
      # Credentials and security policy: owners only.
      {:noreply,
       socket
       |> put_flash(:error, "Those settings are limited to account owners.")
       |> push_patch(to: ~p"/settings/general")}
    else
      {:noreply,
       socket
       |> assign(:section, section)
       |> assign(:page_title, section(section).title)
       |> assign_form(section)
       |> assign_templates(section)
       |> assign_deliveries(section)
       |> assign_calendars(section)
       |> assign_company(section)}
    end
  end

  # Backup: the download is the whole database and a restore replaces it.
  @owner_only_sections [:smtp, :integrations, :security, :backup]

  @doc """
  Whether a settings section is owner-only.

  Public so the navigation can hide what it would refuse to open, rather than
  offering a link that bounces.
  """
  def owner_only?(section), do: section in @owner_only_sections

  # The specimen invoice is built from the organisation, so it moves with it.
  defp assign_organization(socket, organization) do
    socket
    |> assign(:organization, Settings.with_installation_rules(organization))
    |> assign(:sample, InvoiceDocument.sample(organization))
    # Inline, so it survives the session's /uploads request timing out; see
    # InvoiceTemplateDesignLive. The template previews keep the path: inlining
    # there would send the file once per preview.
    |> assign(:logo_src, InvoicePdfGenerator.inline_logo(organization.doc_logo_path))
  end

  defp assign_deliveries(socket, :smtp), do: assign_deliveries(socket)
  defp assign_deliveries(socket, _section), do: socket

  defp assign_deliveries(socket) do
    assign(socket, :deliveries, Mail.list_recent_deliveries(8))
  end

  defp assign_calendars(socket, :integrations) do
    socket
    |> assign(:calendar_connections, Calendars.connections(socket.assigns.current_scope))
    |> assign(:google_configured, GoogleClient.configured?())
    |> assign(:new_feed_url, nil)
    |> assign_caldav_form(Calendars.change_caldav())
  end

  defp assign_calendars(socket, _section), do: socket

  defp assign_company(socket, :company) do
    assign(
      socket,
      :member_count,
      length(Accounts.list_members(socket.assigns.current_scope.business))
    )
  end

  defp assign_company(socket, _section), do: socket

  defp assign_caldav_form(socket, changeset) do
    assign(socket, :caldav_form, to_form(changeset, as: :caldav))
  end

  # Only here: ensure_default/0 writes.
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

  # Bare /settings opens the read-only profile: the page anyone can see.
  defp section_from(nil), do: :company

  defp section_from(value) do
    Enum.find_value(sections(), :company, fn s -> if to_string(s.key) == value, do: s.key end)
  end

  # From the scrubbed organisation, so stored credentials never reach the browser.
  defp assign_form(socket, section) when section in @saveable do
    changeset =
      socket.assigns.organization
      |> Organization.scrub_secrets()
      |> Settings.change_organization(%{}, section)

    assign(socket, :form, to_form(changeset, as: "organization"))
  end

  defp assign_form(socket, _section), do: assign(socket, :form, nil)

  # ── Invoice designs ──
  # List actions; the design itself is edited in InvoiceTemplateDesignLive.

  # ── Text tools ──
  # Write the design's page setup, not a settings column.

  def handle_event("toggle_text_tools", %{"id" => id}, socket) do
    open = if to_string(socket.assigns.open_tools) == id, do: nil, else: template_id(id)

    {:noreply, assign(socket, :open_tools, open)}
  end

  def handle_event("update_page", %{"template_id" => id, "page" => params}, socket) do
    {:noreply, save_page(socket, id, &Layout.cast_page(&1, params))}
  end

  def handle_event("reset_text", %{"id" => id}, socket) do
    {:noreply, save_page(socket, id, fn _page -> Layout.default_page() end)}
  end

  # ── New design: the starter gallery and Import ──

  def handle_event("new_template", _params, socket) do
    {:noreply, socket |> assign(:gallery_open, true) |> assign(:import_open, false)}
  end

  def handle_event("close_gallery", _params, socket) do
    {:noreply, assign(socket, :gallery_open, false)}
  end

  def handle_event("create_from_preset", %{"preset" => key}, socket) do
    with true <- Catalog.preset?(key),
         {:ok, template} <- Templates.create_from_preset(key) do
      {:noreply, push_navigate(socket, to: ~p"/invoice-templates/#{template.id}")}
    else
      _error -> {:noreply, put_flash(socket, :error, "That design could not be created.")}
    end
  end

  def handle_event("toggle_import", _params, socket) do
    {:noreply,
     socket
     |> assign(:import_open, !socket.assigns.import_open)
     |> assign(:gallery_open, false)
     |> assign(:import_error, nil)}
  end

  # Uploads need a change event to report into; the files act on arrival.
  def handle_event("validate_import", _params, socket) do
    {:noreply, assign(socket, :import_error, import_upload_error(socket))}
  end

  def handle_event("cancel_import", %{"ref" => ref, "upload" => name}, socket)
      when name in ["design_file", "letterhead"] do
    upload = if name == "letterhead", do: :letterhead, else: :design_file
    {:noreply, cancel_upload(socket, upload, ref)}
  end

  def handle_event("duplicate_template", %{"id" => id}, socket) do
    with_template(socket, id, &Templates.duplicate_template/1, "That design could not be copied.")
  end

  def handle_event("set_default_template", %{"id" => id}, socket) do
    with_template(socket, id, &Templates.set_default/1, "That design could not be made default.")
  end

  def handle_event("delete_template", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id

    with_template(
      socket,
      id,
      &Templates.delete_template(&1, user_id: user_id),
      "That design could not be removed."
    )
  end

  def handle_event("validate", %{"organization" => params}, socket) do
    changeset =
      socket.assigns.organization
      |> Organization.scrub_secrets()
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
         |> assign_organization(organization)
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
    delete_logo_file(organization.doc_logo_path)

    case Settings.update_section(organization, %{"doc_logo_path" => nil}, :customization) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign_organization(organization)
         |> assign_form(:customization)
         |> put_flash(:info, "Logo removed.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That logo could not be removed.")}
    end
  end

  def handle_event("cancel_logo", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :logo, ref)}
  end

  # Synchronous: reports what the relay said.
  def handle_event("send_test_email", _params, socket) do
    if Scope.owner?(socket.assigns.current_scope),
      do: send_test_email(socket),
      else: {:noreply, put_flash(socket, :error, "Those settings are limited to account owners.")}
  end

  # The section is checked on navigation, but an event can be sent from any of them.
  def handle_event("delete_delivery", %{"id" => id}, socket) do
    if Scope.owner?(socket.assigns.current_scope) do
      case Mail.delete_delivery(id) do
        {:ok, _delivery} ->
          {:noreply, socket |> put_flash(:info, "Delivery removed.") |> assign_deliveries()}

        {:error, _reason} ->
          {:noreply,
           socket |> put_flash(:error, "That delivery is already gone.") |> assign_deliveries()}
      end
    else
      {:noreply, put_flash(socket, :error, "Those settings are limited to account owners.")}
    end
  end

  # Like the events around them, these check the owner themselves: the section
  # is guarded on navigation, but an event can be sent from any of them.
  def handle_event("connect_caldav", %{"caldav" => params}, socket) do
    owner_only(socket, fn ->
      case Calendars.connect_caldav(socket.assigns.current_scope, params) do
        {:ok, _connection} ->
          socket
          |> put_flash(:info, "CalDAV calendar connected. Your deadlines are on their way.")
          |> assign_calendars(:integrations)

        {:error, %Ecto.Changeset{} = changeset} ->
          assign_caldav_form(socket, changeset)
      end
    end)
  end

  def handle_event("disconnect_calendar", %{"provider" => provider}, socket) do
    owner_only(socket, fn ->
      case Calendars.disconnect(socket.assigns.current_scope, provider) do
        {:ok, _connection} ->
          socket
          |> put_flash(:info, "Disconnected. Events already in that calendar stay there.")
          |> assign_calendars(:integrations)

        {:error, _reason} ->
          socket
          |> put_flash(:error, "That calendar is already disconnected.")
          |> assign_calendars(:integrations)
      end
    end)
  end

  def handle_event("sync_calendars", _params, socket) do
    owner_only(socket, fn ->
      _ = Calendars.enqueue_sync()

      socket
      |> put_flash(:info, "Sync started. Reload this page in a moment to see how it went.")
      |> assign(
        :calendar_connections,
        Calendars.connections(socket.assigns.current_scope)
      )
    end)
  end

  def handle_event("regenerate_feed", _params, socket) do
    owner_only(socket, fn ->
      scope = socket.assigns.current_scope

      case Calendars.regenerate_feed(scope) do
        {:ok, token} ->
          socket
          |> assign_calendars(:integrations)
          |> assign(:new_feed_url, url(~p"/calendar/#{scope.business.slug}/#{token <> ".ics"}"))

        {:error, _changeset} ->
          put_flash(socket, :error, "The calendar link could not be created. Try again.")
      end
    end)
  end

  # A restore replaces every record in the business. The section is owner-only,
  # but an event can be sent from any section, so this checks again.
  def handle_event("restore_backup", _params, socket) do
    if Scope.owner?(socket.assigns.current_scope) do
      restore_backup(socket)
    else
      {:noreply, put_flash(socket, :error, "Those settings are limited to account owners.")}
    end
  end

  defp send_test_email(socket) do
    recipient = test_recipient(socket.assigns)

    case recipient && Mail.send_test(recipient) do
      {:ok, _metadata} ->
        {:noreply,
         socket
         |> put_flash(:info, test_sent_message(recipient))
         |> assign_deliveries()}

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, "The relay refused it: #{message}")
         |> assign_deliveries()}

      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Set a contact email address first — there is nobody to send a test to."
         )}
    end
  end

  defp owner_only(socket, action) do
    if Scope.owner?(socket.assigns.current_scope) do
      {:noreply, action.()}
    else
      {:noreply, put_flash(socket, :error, "Those settings are limited to account owners.")}
    end
  end

  defp restore_backup(socket) do
    entries =
      consume_uploaded_entries(socket, :backup_file, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case entries do
      [json_content] ->
        case QuantumBilling.Backup.restore_json(json_content) do
          {:ok, counts} ->
            QuantumBilling.SecurityAlerts.admin_event(
              socket.assigns.current_scope.business,
              socket.assigns.current_scope.user,
              "restored a backup into the business"
            )

            {:noreply,
             socket
             |> put_flash(:info, "Restored #{restored_summary(counts)}.")
             |> assign_organization(Settings.get_organization())
             |> assign_form(socket.assigns.section)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Restore failed: #{reason}")}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "Please upload a valid JSON backup file first.")}
    end
  end

  defp restored_summary(counts) do
    [
      {:clients, "clients"},
      {:invoices, "invoices"},
      {:templates, "designs"},
      {:recurring_profiles, "recurring profiles"},
      {:credit_notes, "credit notes"}
    ]
    |> Enum.map(fn {key, label} -> "#{Map.get(counts, key, 0)} #{label}" end)
    |> Enum.join(", ")
  end

  # Re-read rather than trusting the assign, which may be stale.
  defp save_page(socket, id, fun) do
    case Templates.get_template(id) do
      nil ->
        assign_templates(socket)

      template ->
        doc = Templates.document_of(template)
        doc = %{doc | page: fun.(doc.page)}

        case Templates.update_template(template, %{"layout_xml" => Layout.to_xml(doc)}) do
          {:ok, _template} -> assign_templates(socket)
          {:error, _changeset} -> put_flash(socket, :error, "That change could not be saved.")
        end
    end
  end

  defp template_id(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> id
    end
  end

  # A stale id re-reads instead of erroring.
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
        # Unlink the old file only once the new one is on disk.
        if previous && previous != path, do: delete_logo_file(previous)
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

  # LiveView rejects these before Uploads.store/2 sees them.
  defp upload_message(:too_large) do
    "That file is larger than #{div(Uploads.max_bytes(), 1_000_000)}MB."
  end

  defp upload_message(:not_accepted), do: "That has to be a PNG, JPEG, GIF or WebP image."
  defp upload_message(:too_many_files), do: "One logo at a time."
  defp upload_message(other), do: "That file could not be uploaded (#{inspect(other)})."

  # A design may show the same file (uploads are content-addressed).
  defp delete_logo_file(path) do
    unless DesignAssets.recorded?(path), do: Uploads.delete(path)
  end

  # ── Import ──
  # A design file becomes a design as it is; a letterhead image becomes the
  # background of a new Letterhead design. Either way the pad opens next, where
  # the spacing can be set to clear the printed header and footer.

  defp handle_import_progress(name, entry, socket) do
    if entry.done? do
      {:noreply, import_entry(socket, name, entry)}
    else
      {:noreply, socket}
    end
  end

  defp import_entry(socket, :design_file, entry) do
    xml = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

    xml
    |> Templates.import_layout(design_name(entry.client_name))
    |> after_import(socket, "That design file could not be imported")
  end

  defp import_entry(socket, :letterhead, entry) do
    stored =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Uploads.store(path, entry.client_type)}
      end)

    with {:ok, path} <- stored,
         :ok <- DesignAssets.record(path, "background") do
      "letterhead"
      |> Catalog.preset()
      |> Layout.put_background(path)
      |> Templates.create_from_document("Letterhead")
      |> after_import(socket, "That letterhead could not be used")
    else
      {:error, message} when is_binary(message) ->
        assign(socket, :import_error, "That image #{message}.")

      _error ->
        assign(socket, :import_error, "That image could not be saved.")
    end
  end

  defp after_import({:ok, template}, socket, _prefix) do
    socket
    |> put_flash(:info, "“#{template.name}” imported — adjust it here.")
    |> push_navigate(to: ~p"/invoice-templates/#{template.id}")
  end

  defp after_import({:error, message}, socket, prefix) when is_binary(message) do
    assign(socket, :import_error, "#{prefix}: #{message}")
  end

  defp after_import({:error, _reason}, socket, prefix) do
    assign(socket, :import_error, "#{prefix}.")
  end

  # "Acme invoice v2.xml" → "Acme invoice v2". Shown only as a design name.
  defp design_name(client_name) do
    name =
      (client_name || "")
      |> Path.rootname()
      |> String.replace(~r/[^\p{L}\p{N} ._()-]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if name == "", do: "Imported design", else: name
  end

  defp import_upload_error(socket) do
    [:design_file, :letterhead]
    |> Enum.flat_map(fn name ->
      upload = socket.assigns.uploads[name]
      upload_errors(upload) ++ Enum.flat_map(upload.entries, &upload_errors(upload, &1))
    end)
    |> case do
      [] -> nil
      [:too_large | _] -> "That file is too large."
      [:not_accepted | _] -> "Choose a .xml design file, or a PNG or JPEG image."
      [:too_many_files | _] -> "One file at a time."
      [other | _] -> "That file could not be uploaded (#{inspect(other)})."
    end
  end

  defp gallery_accent(templates) do
    case Enum.find(templates, & &1.is_default) do
      %{accent: "#" <> _ = accent} -> accent
      _none -> "#18181b"
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      active_sub={@section}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        {section(@section).title}
        <:actions :if={@form}>
          <button type="submit" form="settings-form" class={action_button_class()}>
            <.icon name="hero-check" class="size-4" /> Save Changes
          </button>
        </:actions>
      </.header>

      <div class="flex flex-1 flex-col gap-3">
        <.card padding="p-4" class="flex flex-1 flex-col">
          {render_panel(assigns)}
        </.card>

        <.card :if={@section == :general} padding="p-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
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

  # Read-only: staff see it too. Each edit lives in the section that owns it.
  defp render_panel(%{section: :company} = assigns) do
    ~H"""
    <div id="company-profile" class="-m-4 flex flex-col">
      <div class="relative h-32 overflow-hidden rounded-t-[inherit] bg-base-300 sm:h-40">
        <.scene_banner
          id="company-banner"
          seed={@current_scope.business.id}
          class="block size-full"
        />
      </div>

      <div class="px-4 pb-5 sm:px-6">
        <div class="-mt-10 flex flex-col gap-4 sm:-mt-12 sm:flex-row sm:items-end sm:justify-between">
          <div class="flex items-end gap-4">
            <span class="relative flex size-20 shrink-0 items-center justify-center overflow-hidden rounded-2xl border-4 border-base-100 bg-base-100 shadow-md sm:size-24">
              <%= if @organization.doc_logo_path do %>
                <img
                  id="company-logo"
                  src={@logo_src}
                  alt={"#{company_display_name(assigns)} logo"}
                  class="max-h-full max-w-full object-contain p-1.5"
                />
              <% else %>
                <span
                  id="company-initials"
                  class="flex size-full items-center justify-center bg-amber-100 text-2xl font-semibold text-amber-800 dark:bg-amber-300/15 dark:text-amber-200"
                >
                  {company_initials(company_display_name(assigns))}
                </span>
              <% end %>
            </span>

            <div class="min-w-0 pb-1">
              <h2 id="company-name" class="truncate text-lg font-semibold tracking-tight sm:text-xl">
                {company_display_name(assigns)}
              </h2>
              <p
                :if={present?(@organization.trade_name)}
                class="truncate text-sm text-base-content/60"
              >
                Trading as {@organization.trade_name}
              </p>
            </div>
          </div>

          <div class="flex flex-wrap gap-2">
            <.link
              navigate={~p"/settings/general"}
              id="company-edit-details"
              class={secondary_button_class()}
            >
              <.icon name="hero-pencil-square" class="size-4" /> Edit details
            </.link>
            <.link
              navigate={~p"/settings/customization"}
              id="company-edit-designs"
              class={secondary_button_class()}
            >
              <.icon name="hero-paint-brush" class="size-4" /> Logo &amp; designs
            </.link>
            <.link
              :if={Scope.owner?(@current_scope)}
              navigate={~p"/settings/team"}
              id="company-team"
              class={secondary_button_class()}
            >
              <.icon name="hero-user-group" class="size-4" /> Team
            </.link>
          </div>
        </div>

        <div class="mt-4 flex flex-wrap gap-1.5">
          <.company_badge :if={present?(@organization.gstin)} icon="hero-receipt-percent">
            GSTIN <span class="font-mono">{@organization.gstin}</span>
          </.company_badge>
          <.company_badge :if={present?(@organization.pan)} icon="hero-identification">
            PAN <span class="font-mono">{@organization.pan}</span>
          </.company_badge>
          <.company_badge :if={present?(@organization.state)} icon="hero-map-pin">
            {@organization.state}
          </.company_badge>
          <.company_badge icon={if(Scope.owner?(@current_scope), do: "hero-star", else: "hero-user")}>
            You are {if Scope.owner?(@current_scope), do: "an owner", else: "staff"}
          </.company_badge>
        </div>

        <dl
          id="company-facts"
          class="mt-5 grid grid-cols-1 gap-px overflow-hidden rounded-2xl border border-base-300 bg-base-300 sm:grid-cols-2 lg:grid-cols-3"
        >
          <.company_fact icon="hero-map" label="Address">
            {company_address(@organization)}
          </.company_fact>
          <.company_fact icon="hero-envelope" label="Email">
            {blank_dash(@organization.email)}
          </.company_fact>
          <.company_fact icon="hero-phone" label="Phone">
            {blank_dash(@organization.phone)}
          </.company_fact>
          <.company_fact icon="hero-calendar-days" label="Financial year">
            {blank_dash(@organization.financial_year)}
          </.company_fact>
          <.company_fact icon="hero-banknotes" label="Currency">
            {blank_dash(@organization.currency)}
          </.company_fact>
          <.company_fact icon="hero-users" label="Team">
            <span id="company-member-count">
              {@member_count} {if @member_count == 1, do: "member", else: "members"}
            </span>
          </.company_fact>
        </dl>

        <p
          :if={not present?(@organization.gstin) and Scope.owner?(@current_scope)}
          id="company-incomplete"
          class="mt-4 flex items-center gap-2 rounded-xl bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-300/10 dark:text-amber-100"
        >
          <.icon name="hero-light-bulb" class="size-4 shrink-0" />
          Add your GSTIN in General settings so it appears on your invoices.
        </p>
      </div>
    </div>
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
      class="grid grid-cols-1 gap-3 sm:grid-cols-2"
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
      <%!-- Separate fields: the e-invoice export needs the city and PIN. --%>
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
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
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

      <div class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2">
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

      <section
        id="payment-details-card"
        class="mt-6 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="mb-3 flex items-start gap-3">
          <span class="flex size-8 shrink-0 items-center justify-center rounded-field bg-base-200">
            <.icon name="hero-building-library" class="size-4 text-base-content/70" />
          </span>
          <div>
            <h3 class="text-sm font-semibold">Payment details</h3>
            <p class="text-xs text-base-content/60">
              Shown by the Payment Details block in your invoice designs. The UPI ID and its QR code come from Integrations.
            </p>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.field
            field={f[:bank_account_name]}
            label="Account Name"
            placeholder="Acme Traders Pvt Ltd"
          />
          <.field field={f[:bank_name]} label="Bank" placeholder="HDFC Bank" />
          <.field
            field={f[:bank_account_number]}
            label="Account Number"
            inputmode="numeric"
            autocomplete="off"
          />
          <.field field={f[:bank_ifsc]} label="IFSC" placeholder="HDFC0001234" />
          <.field field={f[:bank_branch]} label="Branch" placeholder="MG Road, Bengaluru" />
        </div>
      </section>
    </.form>
    """
  end

  defp render_panel(%{section: :e_way_bill} = assigns) do
    ~H"""
    <.form :let={f} for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
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
          type="money"
          hint="An e-way bill is required above this consignment value."
        />
      </div>

      <div class="mt-4">
        <%!-- The switch is saved, but nothing generates bills automatically yet. --%>
        <.toggle
          field={f[:ewb_auto_generate]}
          label="Flag invoices that need an e-way bill"
          hint={
            "Invoices above the threshold are listed on the Generate E-Way Bill page. " <>
              "Bills are not raised automatically — each one is still confirmed by hand, " <>
              "because the transport details are not on the invoice."
          }
        />
      </div>
    </.form>
    """
  end

  defp render_panel(%{section: :tax} = assigns) do
    ~H"""
    <.form :let={f} for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
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

      <div class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.field
          field={f[:reminder_lead_days]}
          label="Remind me this many days ahead"
          type="number"
          min="1"
          max="60"
        />
      </div>
    </.form>

    <div class="mt-4 border-t border-base-300 pt-5">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h3 class="text-sm font-semibold tracking-tight">SMTP Mailer Test</h3>
          <p class="mt-1 text-xs text-base-content/60">
            Send a sample invoice PDF email to test your SMTP server configuration.
          </p>
        </div>

        <button
          type="button"
          phx-click="send_test_email"
          class={action_button_class()}
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
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
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

    <div class="mt-4 border-t border-base-300 pt-5">
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
    <div class="space-y-4">
      <.form
        :let={f}
        for={@form}
        id="settings-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-3"
      >
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
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
          label="Enforce 2FA for everyone"
          hint="Requires two-factor authentication on every login."
        />

        <p id="installation-rules-note" class="flex items-start gap-1.5 text-xs text-base-content/55">
          <.icon name="hero-information-circle" class="mt-px size-3.5 shrink-0" />
          The IP ranges, session timeout and 2FA rule apply to every business on this
          installation. Audit log retention is this business's own.
        </p>
      </.form>

      <hr class="border-base-300" />

      <dl class="space-y-3">
        <div class="flex items-start justify-between gap-3 border-b border-base-300 pb-4">
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
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
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

    <div class="mt-4 border-t border-base-300 pt-5">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h3 class="text-sm font-semibold tracking-tight">Test SMTP Mail Dispatch</h3>
          <p class="mt-1 text-xs text-base-content/60">
            Sends a short message through these settings, right now, and reports exactly what the
            relay said.
          </p>
        </div>

        <button
          type="button"
          phx-click="send_test_email"
          class={action_button_class()}
        >
          <.icon name="hero-paper-airplane" class="size-4" /> Send Test Email
        </button>
      </div>
    </div>

    <div class="mt-4 border-t border-base-300 pt-5">
      <h3 class="text-sm font-semibold tracking-tight">Recent Deliveries</h3>
      <p class="mt-1 text-xs text-base-content/60">
        Every message the application has tried to send, whether it arrived, and what went wrong
        if it did not. Invoice mail is queued and retried in the background, so a failure here
        outlives the page that caused it.
      </p>

      <p :if={@deliveries == []} class="mt-4 text-xs text-base-content/45">
        Nothing has been sent yet.
      </p>

      <div :if={@deliveries != []} class="mt-3 overflow-x-auto">
        <table id="deliveries" class="table table-sm table-fixed">
          <thead>
            <tr class={table_head_class()}>
              <th class="w-28">When</th>
              <th class="w-56">To</th>
              <th>Subject</th>
              <th class="w-40">Status</th>
              <th class="w-12"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={delivery <- @deliveries}
              id={"delivery-#{delivery.id}"}
              class="align-middle text-xs"
            >
              <td class="whitespace-nowrap text-base-content/50">
                {Calendar.strftime(delivery.inserted_at, "%d %b %H:%M")}
              </td>
              <td class="truncate" title={delivery.to_email}>{delivery.to_email}</td>
              <td class="truncate text-base-content/60" title={delivery.subject}>
                {delivery.subject}
              </td>
              <td>
                <span class={[
                  "badge badge-sm",
                  delivery.status == "sent" && "badge-success",
                  delivery.status == "failed" && "badge-error",
                  delivery.status == "queued" && "badge-ghost"
                ]}>
                  {delivery.status}
                </span>
                <span
                  :if={delivery.last_error}
                  class="mt-0.5 block truncate text-2xs text-error"
                  title={delivery.last_error}
                >
                  {delivery.last_error}
                </span>
              </td>
              <td class="text-right">
                <button
                  type="button"
                  id={"delivery-delete-#{delivery.id}"}
                  phx-click="delete_delivery"
                  phx-value-id={delivery.id}
                  data-confirm="Remove this delivery from the log?"
                  class={row_delete_class()}
                  aria-label={"Remove delivery to #{delivery.to_email}"}
                  title="Remove from log"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp render_panel(%{section: :customization} = assigns) do
    ~H"""
    <div class="space-y-4">
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
            <img src={@logo_src} alt="Current logo" class="max-h-10 max-w-full" />
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
          PNG, JPEG, GIF or WebP, up to {div(Uploads.max_bytes(), 1_000_000)}MB.
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
              Build your own layout block by block, and set each one's typography
              with its own text tools. New invoices use the default; an invoice
              keeps the design it was issued with.
            </p>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <button
              id="import-design"
              type="button"
              phx-click="toggle_import"
              aria-expanded={to_string(@import_open)}
              aria-controls="import-panel"
              class={secondary_button_class()}
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Import
            </button>

            <button
              id="new-design"
              type="button"
              phx-click="new_template"
              class={action_button_class()}
            >
              <.icon name="hero-plus" class="size-4" /> New design
            </button>
          </div>
        </div>

        <.import_panel
          :if={@import_open}
          uploads={@uploads}
          error={@import_error}
        />

        <.preset_gallery
          :if={@gallery_open}
          invoice={@sample}
          logo={@organization.doc_logo_path}
          accent={gallery_accent(@templates)}
        />

        <.template_list
          templates={@templates}
          invoice={@sample}
          logo={@organization.doc_logo_path}
          open_tools={@open_tools}
        />
      </div>
    </div>
    """
  end

  defp render_panel(%{section: :backup} = assigns) do
    ~H"""
    <div class="space-y-4">
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
            class={[action_button_class(), "disabled:opacity-50"]}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Execute Restore
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp render_panel(%{section: :integrations} = assigns) do
    # Read from the environment, which is what the portal clients act on.
    assigns =
      assign(assigns,
        portal_modes: [
          {"irp-mode", "E-invoicing (IRP)", mode(IRPClient.live?()),
           "IRP_CLIENT_ID, IRP_CLIENT_SECRET and IRP_SANDBOX=false"},
          {"nic-mode", "E-way bills (NIC)", mode(NICClient.live?()),
           "NIC_EWB_API_URL and NIC_EWB_API_KEY"}
        ]
      )

    ~H"""
    <section id="government-portals" class="mb-4 rounded-xl border border-base-300 p-4">
      <h3 class="text-sm font-semibold tracking-tight">Government portals</h3>
      <p class="mt-1 text-xs text-base-content/60">
        Whether IRNs and e-way bills are filed with the government or generated locally for
        demonstration. Every result is labelled with the mode that produced it.
      </p>

      <ul class="mt-3 divide-y divide-base-200">
        <li
          :for={{id, label, mode, env} <- @portal_modes}
          class="flex flex-col gap-1 py-2 sm:flex-row sm:items-center sm:justify-between"
        >
          <div>
            <p class="text-sm font-medium">{label}</p>
            <p class="text-xs text-base-content/60">
              <%= if mode == "live" do %>
                Requests go to the portal; if it does not answer, you see an error and nothing is
                recorded.
              <% else %>
                Numbers are generated locally and are not filed. To go live, set {env} on the
                server.
              <% end %>
            </p>
          </div>
          <.portal_mode_badge id={id} mode={mode} />
        </li>
      </ul>
    </section>

    <.calendar_cards
      connections={@calendar_connections}
      google_configured={@google_configured}
      caldav_form={@caldav_form}
      new_feed_url={@new_feed_url}
    />

    <.form
      :let={f}
      for={@form}
      id="settings-form"
      phx-change="validate"
      phx-submit="save"
      class="space-y-4"
    >
      <div>
        <h3 class="text-sm font-semibold tracking-tight">UPI Payments</h3>
        <p class="mt-1 text-xs text-base-content/60">
          The UPI ID customers pay into. It is printed on every invoice and encoded into its
          payment QR code — without it, no payment QR is drawn.
        </p>

        <div class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.field
            field={f[:upi_vpa]}
            label="UPI ID (VPA)"
            placeholder="yourbusiness@okhdfcbank"
            hint="A UPI ID from your bank or PSP — not an email address."
          />
          <.field
            field={f[:upi_payee_name]}
            label="Payee Name (optional)"
            placeholder="Shown while the payer confirms"
          />
        </div>
      </div>

      <hr class="border-base-300" />

      <div>
        <h3 class="text-sm font-semibold tracking-tight">Razorpay Payment Gateway</h3>
        <p class="mt-1 text-xs text-base-content/60">
          API key credentials for generating invoice payment links. Without them, payment links
          are refused rather than simulated.
        </p>

        <div class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.field field={f[:razorpay_key_id]} label="Razorpay Key ID" placeholder="rzp_live_..." />
          <.field
            field={f[:razorpay_key_secret]}
            label="Razorpay Key Secret"
            type="password"
            placeholder="••••••••••••"
          />
        </div>

        <div id="razorpay-webhook" class="mt-3 rounded-lg border border-base-300 bg-base-200/40 p-3">
          <p class="text-xs font-medium text-base-content/70">Webhook URL for this business</p>
          <code
            id="razorpay-webhook-url"
            class="mt-1 block select-all break-all font-mono text-xs text-base-content"
          >
            {url(~p"/api/webhooks/razorpay/#{@current_scope.business.slug}")}
          </code>
          <p class="mt-1 text-xs text-base-content/60">
            Paste this into the Razorpay dashboard for {@current_scope.business.name}. Each business has its own,
            so a payment is recorded against the right firm.
          </p>
        </div>
      </div>

      <hr class="border-base-300" />

      <div>
        <h3 class="text-sm font-semibold tracking-tight">Government IRP / NIC E-Invoice API</h3>
        <p class="mt-1 text-xs text-base-content/60">
          Configure direct IRP / ClearTax API credentials for 1-click IRN & Signed QR code fetching.
        </p>

        <div class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-3">
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
        <h3 class="text-sm font-semibold tracking-tight">Event webhooks</h3>
        <p class="mt-1 text-xs text-base-content/60">
          Send signed events — invoices created, updated and paid, e-invoicing, e-way bills,
          clients and credit notes — to your own systems.
        </p>
        <.link
          id="webhooks-settings-link"
          navigate={~p"/settings/webhooks"}
          class="mt-3 inline-flex items-center gap-1.5 text-xs font-medium text-primary hover:underline"
        >
          <.icon name="hero-arrow-right" class="size-3.5" /> Manage webhook endpoints
        </.link>
      </div>
    </.form>
    """
  end

  # The signed-in user, then the organisation's address; never a client.
  defp test_recipient(%{current_scope: scope, organization: organization}),
    do: test_recipient(scope, organization)

  defp test_recipient(scope, organization) do
    presence(scope && scope.user && scope.user.email) || presence(organization.email)
  end

  # With no relay in development, mail goes to the local preview.
  defp test_sent_message(recipient) do
    local_preview? =
      not Mail.own_relay?(Settings.get_organization()) and
        Application.get_env(:quantum_billing, QuantumBilling.Mailer)[:adapter] ==
          Swoosh.Adapters.Local

    if local_preview? do
      "No SMTP relay is set, so the test went to the local preview at /dev/mailbox, " <>
        "not to #{recipient}."
    else
      "Test email sent to #{recipient}."
    end
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value

  defp mode(true), do: "live"
  defp mode(false), do: "demo"

  # ── Company profile helpers ──

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp company_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 rounded-full border border-base-300 bg-base-200/60 px-2.5 py-1 text-xs text-base-content/75">
      <.icon name={@icon} class="size-3.5 text-base-content/50" />
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp company_fact(assigns) do
    ~H"""
    <div class="flex gap-3 bg-base-100 p-3.5">
      <span class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-base-200 text-base-content/60">
        <.icon name={@icon} class="size-4" />
      </span>
      <div class="min-w-0">
        <dt class="text-xs text-base-content/50">{@label}</dt>
        <dd class="mt-0.5 break-words text-sm font-medium">{render_slot(@inner_block)}</dd>
      </div>
    </div>
    """
  end

  defp company_display_name(%{organization: organization, current_scope: scope}) do
    if present?(organization.company_name),
      do: organization.company_name,
      else: scope.business.name
  end

  defp company_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp company_address(organization) do
    [organization.address, organization.city, organization.pincode]
    |> Enum.filter(&present?/1)
    |> Enum.join(", ")
    |> blank_dash()
  end

  defp blank_dash(value), do: if(present?(value), do: value, else: "—")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  attr :invoice, :map, required: true
  attr :logo, :string, default: nil
  attr :accent, :string, required: true

  defp preset_gallery(assigns) do
    assigns = assign(assigns, :presets, Enum.map(Catalog.presets(), &preset_entry/1))

    ~H"""
    <section
      id="preset-gallery"
      class="mb-4 rounded-box border border-base-300 bg-base-200/50 p-4"
    >
      <div class="mb-3 flex items-start justify-between gap-3">
        <div>
          <h4 class="text-sm font-semibold tracking-tight">Start from a design</h4>
          <p class="mt-0.5 text-xs text-base-content/60">
            Pick a starting point. Everything in it can be changed on the design pad.
          </p>
        </div>

        <button
          id="close-gallery"
          type="button"
          phx-click="close_gallery"
          class="rounded-field p-1 text-base-content/50 transition hover:bg-base-300 hover:text-base-content"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <div class="grid grid-cols-2 gap-3 md:grid-cols-3">
        <button
          :for={{key, name, description, doc} <- @presets}
          id={"preset-#{key}"}
          type="button"
          phx-click="create_from_preset"
          phx-value-preset={key}
          phx-disable-with="Creating…"
          class="group flex flex-col overflow-hidden rounded-box border border-base-300 bg-base-100 text-left transition duration-150 hover:-translate-y-0.5 hover:border-base-content/30 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content motion-reduce:transition-none motion-reduce:hover:translate-y-0"
        >
          <div class="pointer-events-none overflow-hidden border-b border-base-300 bg-base-100">
            <Renderer.stylesheet doc={doc} />
            <Renderer.thumbnail
              doc={doc}
              invoice={@invoice}
              accent={@accent}
              logo={@logo}
              scale={0.3}
            />
          </div>
          <div class="p-2.5">
            <p class="flex items-center justify-between gap-2 text-sm font-medium">
              {name}
              <.icon
                name="hero-arrow-right"
                class="size-3.5 text-base-content/30 transition group-hover:translate-x-0.5 group-hover:text-base-content"
              />
            </p>
            <p class="mt-0.5 line-clamp-2 text-2xs text-base-content/55">{description}</p>
          </div>
        </button>
      </div>
    </section>
    """
  end

  defp preset_entry({key, name, description}),
    do: {key, name, description, Catalog.preset(key)}

  attr :uploads, :map, required: true
  attr :error, :string, default: nil

  defp import_panel(assigns) do
    ~H"""
    <section
      id="import-panel"
      class="mb-4 rounded-box border border-base-300 bg-base-200/50 p-4"
    >
      <h4 class="text-sm font-semibold tracking-tight">Import your own invoice</h4>
      <p class="mt-0.5 text-xs text-base-content/60">
        Bring in a design exported from QuantumBilling, or use your existing invoice or letterhead as the page background.
      </p>

      <form
        id="import-form"
        phx-change="validate_import"
        class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2"
      >
        <label
          id="import-design-file"
          class="group flex cursor-pointer items-start gap-3 rounded-box border border-dashed border-base-300 bg-base-100 p-3.5 transition hover:border-base-content/40 hover:bg-base-100/70"
        >
          <span class="flex size-9 shrink-0 items-center justify-center rounded-field bg-base-200 transition group-hover:scale-105">
            <.icon name="hero-code-bracket-square" class="size-5 text-base-content/70" />
          </span>
          <span class="min-w-0">
            <span class="block text-sm font-medium">Design file</span>
            <span class="mt-0.5 block text-2xs text-base-content/55">
              A .xml file from Export, up to {div(Templates.max_import_bytes(), 1000)}KB.
            </span>
          </span>
          <.live_file_input upload={@uploads.design_file} class="sr-only" />
        </label>

        <label
          id="import-letterhead"
          class="group flex cursor-pointer items-start gap-3 rounded-box border border-dashed border-base-300 bg-base-100 p-3.5 transition hover:border-base-content/40 hover:bg-base-100/70"
        >
          <span class="flex size-9 shrink-0 items-center justify-center rounded-field bg-base-200 transition group-hover:scale-105">
            <.icon name="hero-document-arrow-up" class="size-5 text-base-content/70" />
          </span>
          <span class="min-w-0">
            <span class="block text-sm font-medium">Invoice or letterhead image</span>
            <span class="mt-0.5 block text-2xs text-base-content/55">
              A PNG or JPEG of your page, up to {div(Uploads.max_bytes(), 1_000_000)}MB. It becomes the background.
            </span>
          </span>
          <.live_file_input upload={@uploads.letterhead} class="sr-only" />
        </label>
      </form>

      <div
        :for={{name, entry} <- import_entries(@uploads)}
        id={"import-entry-#{entry.ref}"}
        class="mt-3 flex items-center gap-2 text-xs"
      >
        <span class="h-1.5 w-24 overflow-hidden rounded-full bg-base-300">
          <span
            class="block h-full rounded-full bg-base-content/70 transition-[width]"
            style={"width: #{entry.progress}%"}
          />
        </span>
        <span class="min-w-0 truncate text-base-content/60">{entry.client_name}</span>
        <button
          type="button"
          phx-click="cancel_import"
          phx-value-ref={entry.ref}
          phx-value-upload={name}
          class="text-error hover:underline"
        >
          Cancel
        </button>
      </div>

      <p :if={@error} id="import-error" class="mt-2 flex items-center gap-1 text-xs text-error">
        <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />{@error}
      </p>
    </section>
    """
  end

  defp import_entries(uploads) do
    Enum.map(uploads.design_file.entries, &{"design_file", &1}) ++
      Enum.map(uploads.letterhead.entries, &{"letterhead", &1})
  end
end
