defmodule QuantumBillingWeb.BinLive do
  @moduledoc """
  The Bin: deleted invoices, clients, e-way bills, recurring profiles and designs.

  Each row offers Restore and Delete permanently (the only hard delete in the
  app). Rows from five contexts are flattened by `entry/1`, and the stream is
  reset on every change so the filter counts stay right. Designs used by
  invoices and clients with credit notes can't be purged. A restore is refused
  when its GSTIN or invoice slot has been taken.

  At most `limit` entries are read: the newest `limit` of each kind, merged.
  The tab counts come from count queries, and "Show more" raises the limit.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Clients
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.EWayBills
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Recurring
  alias QuantumBilling.Recurring.RecurringProfile
  alias QuantumBilling.Templates
  alias QuantumBilling.Templates.InvoiceTemplate

  @filters [
    {"all", "All", "hero-squares-2x2"},
    {"invoice", "Invoices", "hero-document-text"},
    {"client", "Clients", "hero-user-group"},
    {"e_way_bill", "E-Way Bills", "hero-truck"},
    {"recurring", "Recurring", "hero-arrow-path"},
    {"template", "Designs", "hero-paint-brush"}
  ]

  # The tile colour behind each kind's icon.
  @tones %{
    "invoice" => "bg-info/12 text-info",
    "client" => "bg-success/12 text-success",
    "e_way_bill" => "bg-warning/15 text-warning",
    "recurring" => "bg-violet-500/12 text-violet-600 dark:text-violet-300",
    "template" => "bg-base-200 text-base-content/70"
  }

  # Entries read per screenful; "Show more" adds another.
  @page_size 100

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Recurring profiles have no topic; they are re-read after each action.
      Invoices.subscribe()
      Clients.subscribe()
      EWayBills.subscribe()
      Templates.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Bin")
     |> assign(:active_nav, :bin)
     |> assign(:filter, "all")
     |> assign(:limit, @page_size)
     |> stream_configure(:entries, dom_id: &"bin-#{&1.id}")
     |> load_entries()}
  end

  def handle_event("filter", %{"type" => type}, socket) do
    if Enum.any?(@filters, fn {key, _label, _icon} -> key == type end) do
      {:noreply, socket |> assign(:filter, type) |> assign(:limit, @page_size) |> load_entries()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("more", _params, socket) do
    {:noreply, socket |> update(:limit, &(&1 + @page_size)) |> load_entries()}
  end

  def handle_event("restore", %{"type" => type, "id" => id}, socket) do
    {:noreply, socket |> act(fetch(type, id), &restore/2) |> load_entries()}
  end

  # Purging destroys a statutory record, so only owners may; the event is checked here too.
  def handle_event("purge", %{"type" => type, "id" => id}, socket) do
    if QuantumBilling.Accounts.Scope.owner?(socket.assigns.current_scope) do
      {:noreply, socket |> act(fetch(type, id), &purge/2) |> load_entries()}
    else
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Only an owner can delete permanently. Ask an owner of this business."
       )
       |> load_entries()}
    end
  end

  def handle_info({:invoice_changed, _invoice}, socket) do
    {:noreply, load_entries(socket)}
  end

  def handle_info({:invoice_template_changed, _template}, socket) do
    {:noreply, load_entries(socket)}
  end

  def handle_info({:e_way_bill_changed, _bill}, socket) do
    {:noreply, load_entries(socket)}
  end

  def handle_info({event, %Client{}}, socket)
      when event in [:client_binned, :client_restored, :client_purged, :client_updated] do
    {:noreply, load_entries(socket)}
  end

  def handle_info({:client_created, %Client{}}, socket), do: {:noreply, socket}
  def handle_info({:clients_imported, _count}, socket), do: {:noreply, socket}

  # ── Actions ───────────────────────────────────────────────────────────────

  # Binned records only.
  defp fetch("invoice", id), do: Invoices.get_deleted_invoice(id)
  defp fetch("client", id), do: Clients.get_deleted_client(id)
  defp fetch("e_way_bill", id), do: EWayBills.get_deleted_e_way_bill(id)
  defp fetch("recurring", id), do: Recurring.get_deleted_profile(id)
  defp fetch("template", id), do: Templates.get_archived_template(id)
  defp fetch(_unknown_type, _id), do: nil

  defp act(socket, nil, _action) do
    put_flash(socket, :error, "That item is no longer in the Bin.")
  end

  defp act(socket, record, action) do
    case action.(record, user_id: socket.assigns.current_scope.user.id) do
      {:ok, message} -> put_flash(socket, :info, message)
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  defp restore(%Invoice{} = invoice, opts) do
    case Invoices.restore_invoice(invoice, opts) do
      {:ok, invoice} -> {:ok, "Invoice #{invoice.invoice_number} restored."}
      {:error, _reason} -> {:error, "That invoice could not be restored."}
    end
  end

  defp restore(%Client{} = client, opts) do
    case Clients.restore_client(client, opts) do
      {:ok, client} ->
        {:ok, "#{client.name} restored."}

      {:error, :gstin_taken} ->
        {:error,
         "#{client.name} cannot be restored: another client is now registered under " <>
           "GSTIN #{client.gstin}."}

      {:error, _reason} ->
        {:error, "That client could not be restored."}
    end
  end

  defp restore(%EWayBill{} = bill, opts) do
    case EWayBills.restore_e_way_bill(bill, opts) do
      {:ok, bill} ->
        {:ok, "E-way bill #{bill.ewb_number} restored."}

      {:error, :invoice_has_live_bill} ->
        {:error,
         "E-way bill #{bill.ewb_number} cannot be restored: its invoice has had another " <>
           "e-way bill raised since."}

      {:error, _reason} ->
        {:error, "That e-way bill could not be restored."}
    end
  end

  defp restore(%RecurringProfile{} = profile, opts) do
    case Recurring.restore_profile(profile, opts) do
      {:ok, profile} -> {:ok, "Recurring profile “#{profile.title}” restored."}
      {:error, _reason} -> {:error, "That recurring profile could not be restored."}
    end
  end

  defp restore(%InvoiceTemplate{name: old_name} = template, opts) do
    case Templates.restore_template(template, opts) do
      {:ok, %InvoiceTemplate{name: ^old_name}} ->
        {:ok, "Design “#{old_name}” restored."}

      # Renamed because its name was taken while binned.
      {:ok, %InvoiceTemplate{name: new_name}} ->
        {:ok, "Design “#{old_name}” restored as “#{new_name}”."}

      {:error, _reason} ->
        {:error, "That design could not be restored."}
    end
  end

  defp purge(%Invoice{} = invoice, opts) do
    case Invoices.purge_invoice(invoice, opts) do
      {:ok, invoice} -> {:ok, "Invoice #{invoice.invoice_number} permanently deleted."}
      {:error, _reason} -> {:error, "That invoice could not be deleted."}
    end
  end

  defp purge(%Client{} = client, opts) do
    case Clients.purge_client(client, opts) do
      {:ok, client} ->
        {:ok, "#{client.name} permanently deleted."}

      {:error, :in_use} ->
        {:error,
         "#{client.name} has credit notes raised against it, so it cannot be permanently deleted."}

      {:error, _reason} ->
        {:error, "That client could not be deleted."}
    end
  end

  defp purge(%EWayBill{} = bill, opts) do
    case EWayBills.purge_e_way_bill(bill, opts) do
      {:ok, bill} -> {:ok, "E-way bill #{bill.ewb_number} permanently deleted."}
      {:error, _reason} -> {:error, "That e-way bill could not be deleted."}
    end
  end

  defp purge(%RecurringProfile{} = profile, opts) do
    case Recurring.purge_profile(profile, opts) do
      {:ok, profile} -> {:ok, "Recurring profile “#{profile.title}” permanently deleted."}
      {:error, _reason} -> {:error, "That recurring profile could not be deleted."}
    end
  end

  defp purge(%InvoiceTemplate{} = template, opts) do
    case Templates.purge_template(template, opts) do
      {:ok, template} ->
        {:ok, "Design “#{template.name}” permanently deleted."}

      {:error, :in_use} ->
        {:error,
         "“#{template.name}” is the design some invoices were issued with, " <>
           "so it cannot be permanently deleted."}

      {:error, _reason} ->
        {:error, "That design could not be deleted."}
    end
  end

  # ── Loading ───────────────────────────────────────────────────────────────

  defp load_entries(socket) do
    %{filter: filter, limit: limit} = socket.assigns
    counts = counts()

    # The newest `limit` of each kind hold the newest `limit` overall.
    shown =
      @filters
      |> Enum.map(fn {key, _label, _icon} -> key end)
      |> Enum.filter(&(filter in ["all", &1] and &1 != "all" and counts[&1] > 0))
      |> Enum.flat_map(&entries(&1, limit))
      |> Enum.sort_by(& &1.deleted_at, {:desc, DateTime})
      |> Enum.take(limit)

    socket
    # Streams cannot be counted, so counts are kept beside them.
    |> assign(:counts, counts)
    |> assign(:shown, length(shown))
    |> assign(:hidden, max(Map.get(counts, filter, 0) - length(shown), 0))
    |> stream(:entries, shown, reset: true)
  end

  defp counts do
    counts = %{
      "invoice" => Invoices.count_deleted_invoices(),
      "client" => Clients.count_deleted_clients(),
      "e_way_bill" => EWayBills.count_deleted_e_way_bills(),
      "recurring" => Recurring.count_deleted_profiles(),
      "template" => Templates.count_archived_templates()
    }

    Map.put(counts, "all", counts |> Map.values() |> Enum.sum())
  end

  defp entries("invoice", limit),
    do: Enum.map(Invoices.list_deleted_invoices(limit: limit), &entry/1)

  defp entries("e_way_bill", limit),
    do: Enum.map(EWayBills.list_deleted_e_way_bills(limit: limit), &entry/1)

  defp entries("recurring", limit),
    do: Enum.map(Recurring.list_deleted_profiles(limit: limit), &entry/1)

  # One in-use query for the screenful, not one per row.
  defp entries("client", limit) do
    clients = Clients.list_deleted_clients(limit: limit)
    in_use = clients |> Enum.map(& &1.id) |> Clients.ids_in_use()
    Enum.map(clients, &entry(&1, MapSet.member?(in_use, &1.id)))
  end

  defp entries("template", limit) do
    templates = Templates.list_archived_templates(limit: limit)
    in_use = templates |> Enum.map(& &1.id) |> Templates.ids_in_use()
    Enum.map(templates, &entry(&1, MapSet.member?(in_use, &1.id)))
  end

  defp entry(%Invoice{} = invoice) do
    %{
      id: "invoice-#{invoice.id}",
      type: "invoice",
      record_id: invoice.id,
      kind: "Invoice",
      icon: "hero-document-text",
      title: invoice.invoice_number,
      subtitle: invoice.client_name,
      details:
        "#{format_date(invoice.invoice_date)} · #{money(invoice.grand_total || 0, invoice.currency)} · #{invoice.status}",
      deleted_at: invoice.deleted_at,
      locked: nil,
      purge_confirm:
        "Permanently delete #{invoice.invoice_number}? Its line items, e-way bills and " <>
          "credit notes go with it. This cannot be undone, and the number is not reused."
    }
  end

  defp entry(%EWayBill{} = bill) do
    %{
      id: "e_way_bill-#{bill.id}",
      type: "e_way_bill",
      record_id: bill.id,
      kind: "E-Way Bill",
      icon: "hero-truck",
      title: bill.ewb_number,
      subtitle: bill.invoice && "#{bill.invoice.invoice_number} · #{bill.invoice.client_name}",
      details:
        "#{format_date(bill.ewb_date)} · #{EWayBills.status(bill)}" <>
          if(bill.vehicle_number, do: " · #{bill.vehicle_number}", else: ""),
      deleted_at: bill.deleted_at,
      locked: nil,
      purge_confirm:
        "Permanently delete e-way bill #{bill.ewb_number}? Its vehicle history goes with it. " <>
          "This cannot be undone, and it does not cancel the bill on the e-way bill portal."
    }
  end

  defp entry(%RecurringProfile{} = profile) do
    %{
      id: "recurring-#{profile.id}",
      type: "recurring",
      record_id: profile.id,
      kind: "Recurring",
      icon: "hero-arrow-path",
      title: profile.title,
      subtitle: profile.client && profile.client.name,
      details: "#{profile.frequency} · next run #{format_date(profile.next_run_date)}",
      deleted_at: profile.deleted_at,
      locked: nil,
      purge_confirm:
        "Permanently delete “#{profile.title}”? This cannot be undone. " <>
          "Invoices it has already issued are kept."
    }
  end

  defp entry(%Client{} = client, in_use?) do
    %{
      id: "client-#{client.id}",
      type: "client",
      record_id: client.id,
      kind: "Client",
      icon: "hero-user-group",
      title: client.name,
      subtitle: client.gstin || client.client_type,
      details:
        [client.email, client.phone]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" · "),
      deleted_at: client.deleted_at,
      locked: if(in_use?, do: "Credit notes were raised against this client, so it is kept."),
      purge_confirm:
        "Permanently delete #{client.name}? This cannot be undone. Its invoices are kept, " <>
          "but are no longer linked to a client record."
    }
  end

  defp entry(%InvoiceTemplate{} = template, in_use?) do
    %{
      id: "template-#{template.id}",
      type: "template",
      record_id: template.id,
      kind: "Design",
      icon: "hero-paint-brush",
      title: template.name,
      subtitle: "Invoice design",
      details: if(in_use?, do: "Used by issued invoices", else: "Not used by any invoice"),
      deleted_at: template.archived_at,
      locked: if(in_use?, do: "Invoices were issued with this design, so it is kept."),
      purge_confirm: "Permanently delete the design “#{template.name}”? This cannot be undone."
    }
  end

  # ── View ──────────────────────────────────────────────────────────────────

  defp tone(type), do: Map.get(@tones, type, "bg-base-200 text-base-content/70")

  @doc false
  # "Deleted today", "Deleted yesterday", "Deleted 3 days ago"; a date past a month.
  def relative_deleted(%DateTime{} = deleted_at, today \\ Date.utc_today()) do
    case Date.diff(today, DateTime.to_date(deleted_at)) do
      days when days <= 0 -> "Deleted today"
      1 -> "Deleted yesterday"
      days when days <= 30 -> "Deleted #{days} days ago"
      _older -> "Deleted on #{format_date(DateTime.to_date(deleted_at))}"
    end
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:filters, @filters)
      |> assign(:owner?, QuantumBilling.Accounts.Scope.owner?(assigns.current_scope))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        Bin
        <:subtitle>
          Deleted invoices, clients, e-way bills, recurring profiles and invoice designs. Restore them, or delete them for good.
        </:subtitle>
      </.header>

      <%!-- Tabs scroll sideways on a phone rather than wrapping. --%>
      <div class="-mx-4 mb-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
        <div id="bin-filters" class="flex min-w-max items-center gap-1 border-b border-base-300">
          <button
            :for={{key, label, icon} <- @filters}
            type="button"
            id={"bin-filter-#{key}"}
            phx-click="filter"
            phx-value-type={key}
            aria-pressed={to_string(@filter == key)}
            class={[
              "relative -mb-px inline-flex h-10 shrink-0 items-center gap-2 border-b-2 px-3 text-sm",
              "transition-colors duration-150",
              if(@filter == key,
                do: "border-base-content font-medium text-base-content",
                else:
                  "border-transparent text-base-content/55 hover:border-base-300 hover:text-base-content"
              )
            ]}
          >
            <.icon name={icon} class="size-4" />
            {label}
            <span
              id={"bin-count-#{key}"}
              class={[
                "min-w-5 rounded-full px-1.5 py-px text-center text-2xs tabular-nums transition-colors",
                if(@filter == key,
                  do: "bg-base-content text-base-100",
                  else: "bg-base-200 text-base-content/60"
                )
              ]}
            >
              {Map.get(@counts, key, 0)}
            </span>
          </button>
        </div>
      </div>

      <div
        id="bin-info"
        class="mb-4 flex items-start gap-2.5 rounded-box border border-base-300 bg-base-200/50 px-3.5 py-2.5 text-xs text-base-content/65"
      >
        <.icon name="hero-information-circle" class="mt-px size-4 shrink-0 text-base-content/45" />
        <p>
          Restored items go back exactly where they were.
          <%= if @owner? do %>
            Delete forever removes an item for good, and cannot be undone.
          <% else %>
            Only an owner can delete items for good.
          <% end %>
        </p>
      </div>

      <div
        :if={@shown == 0}
        id="bin-empty"
        class="flex flex-1 flex-col justify-center rounded-box border border-dashed border-base-300 bg-base-100 py-6"
      >
        <.empty_state
          icon="hero-trash"
          title={
            if(@filter == "all", do: "The Bin is empty", else: "Nothing of this kind in the Bin")
          }
          description={
            if(@filter == "all",
              do:
                "Invoices, clients, e-way bills, recurring profiles and designs you delete are kept here until you delete them permanently.",
              else: "Choose All to see everything that has been deleted."
            )
          }
        />
      </div>

      <%!-- Hidden rather than removed: the stream container must stay in the DOM. --%>
      <div
        id="bin-entries"
        phx-update="stream"
        class={["flex flex-col gap-2", @shown == 0 && "hidden"]}
      >
        <div
          :for={{dom_id, entry} <- @streams.entries}
          id={dom_id}
          class={[
            "group flex flex-col gap-3 rounded-box border border-base-300 bg-base-100 p-3",
            "transition duration-150 hover:-translate-y-px hover:border-base-content/20 hover:shadow-sm",
            "sm:flex-row sm:items-center sm:gap-4 sm:px-4"
          ]}
        >
          <div class="flex min-w-0 flex-1 items-start gap-3 sm:items-center">
            <span class={[
              "flex size-10 shrink-0 items-center justify-center rounded-field",
              tone(entry.type)
            ]}>
              <.icon name={entry.icon} class="size-5" />
            </span>

            <div class="min-w-0 flex-1">
              <div class="flex min-w-0 items-center gap-2">
                <p class="truncate font-medium">{entry.title}</p>
                <span class="shrink-0 rounded-full border border-base-300 px-1.5 py-px text-2xs font-medium uppercase tracking-wide text-base-content/55">
                  {entry.kind}
                </span>
              </div>

              <p :if={entry.subtitle} class="truncate text-xs text-base-content/70">
                {entry.subtitle}
              </p>

              <p :if={entry.details not in [nil, ""]} class="truncate text-xs text-base-content/50">
                {entry.details}
              </p>
            </div>
          </div>

          <div class="flex items-center justify-between gap-3 border-t border-base-200 pt-3 sm:shrink-0 sm:justify-end sm:border-0 sm:pt-0">
            <span
              class="inline-flex items-center gap-1 whitespace-nowrap text-xs text-base-content/50"
              title={Calendar.strftime(entry.deleted_at, "%d %b %Y, %H:%M UTC")}
            >
              <.icon name="hero-clock" class="size-3.5" />
              {relative_deleted(entry.deleted_at)}
            </span>

            <div class="flex items-center gap-1.5">
              <button
                type="button"
                id={"bin-restore-#{entry.id}"}
                phx-click="restore"
                phx-value-type={entry.type}
                phx-value-id={entry.record_id}
                aria-label={"Restore #{entry.title}"}
                class={[
                  "inline-flex h-8 items-center gap-1.5 rounded-field border border-base-300 bg-base-100 px-3",
                  "text-xs font-medium text-base-content/80 transition",
                  "hover:border-base-content/25 hover:bg-base-200 hover:text-base-content active:scale-[.98]"
                ]}
              >
                <.icon name="hero-arrow-uturn-left" class="size-3.5" /> Restore
              </button>

              <button
                :if={!entry.locked and @owner?}
                type="button"
                id={"bin-purge-#{entry.id}"}
                phx-click="purge"
                phx-value-type={entry.type}
                phx-value-id={entry.record_id}
                data-confirm={entry.purge_confirm}
                aria-label={"Delete forever: #{entry.title}"}
                class={[
                  "inline-flex h-8 items-center gap-1.5 rounded-field px-3 text-xs font-medium text-error/85",
                  "transition hover:bg-error/10 hover:text-error active:scale-[.98]"
                ]}
              >
                <.icon name="hero-trash" class="size-3.5" /> Delete forever
              </button>

              <span
                :if={entry.locked}
                id={"bin-locked-#{entry.id}"}
                title={entry.locked}
                aria-label={"In use: #{entry.locked}"}
                class="inline-flex h-8 cursor-help items-center gap-1 rounded-full bg-base-200 px-2.5 text-xs text-base-content/60"
              >
                <.icon name="hero-lock-closed" class="size-3.5" /> In use
              </span>
            </div>
          </div>
        </div>
      </div>

      <div :if={@hidden > 0} id="bin-more" class="mt-4 flex flex-col items-center gap-2">
        <p class="text-xs text-base-content/60">
          Showing the {@shown} most recently deleted. {@hidden} more {if(@hidden == 1,
            do: "item is",
            else: "items are"
          )} older.
        </p>
        <button
          type="button"
          id="bin-show-more"
          phx-click="more"
          phx-disable-with="Loading…"
          class="btn btn-sm btn-ghost border border-base-300 transition hover:-translate-y-px hover:shadow-sm"
        >
          <.icon name="hero-chevron-double-down" class="size-4" /> Show more
        </button>
      </div>
    </Layouts.app>
    """
  end
end
