defmodule QuantumBillingWeb.BinLive do
  @moduledoc """
  The Bin: everything that has been deleted and can still be brought back.

  Five kinds of record land here — invoices, clients, e-way bills, recurring
  profiles and invoice designs — because those are the five the application
  lets you delete. Each row offers the same two actions: **Restore**, which puts the record back
  exactly as it was, and **Delete permanently**, which is the delete that
  cannot be undone and is the only place in the application that does it.

  ## One list, five sources

  The rows come from five contexts and are flattened into one shape,
  `entry/1`, so the table does not have to know which kind it is drawing. The
  list is a stream and is reset on every change rather than patched: restoring
  one row changes the counts on the filter chips, and a list that is re-read
  whole cannot drift from them.

  ## What cannot be purged

  A design that invoices were issued under cannot be deleted permanently — the
  row is the record of which design those invoices carry — and neither can a
  client that credit notes were raised against. Their rows say so instead of
  offering a button that would fail.

  ## What cannot always be restored

  A client comes back into its GSTIN and an e-way bill into its invoice's one
  live slot, and either may have been taken while the record was in the Bin.
  The restore is then refused with the reason.
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
    {"all", "All"},
    {"invoice", "Invoices"},
    {"client", "Clients"},
    {"e_way_bill", "E-Way Bills"},
    {"recurring", "Recurring"},
    {"template", "Designs"}
  ]

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
     |> stream_configure(:entries, dom_id: &"bin-#{&1.id}")
     |> load_entries()}
  end

  def handle_event("filter", %{"type" => type}, socket) do
    if Enum.any?(@filters, fn {key, _label} -> key == type end) do
      {:noreply, socket |> assign(:filter, type) |> load_entries()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore", %{"type" => type, "id" => id}, socket) do
    {:noreply, socket |> act(fetch(type, id), &restore/2) |> load_entries()}
  end

  def handle_event("purge", %{"type" => type, "id" => id}, socket) do
    {:noreply, socket |> act(fetch(type, id), &purge/2) |> load_entries()}
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
    entries =
      Enum.map(Invoices.list_deleted_invoices(), &entry/1) ++
        Enum.map(Clients.list_deleted_clients(), &entry/1) ++
        Enum.map(EWayBills.list_deleted_e_way_bills(), &entry/1) ++
        Enum.map(Recurring.list_deleted_profiles(), &entry/1) ++
        Enum.map(Templates.list_archived_templates(), &entry/1)

    counts =
      entries
      |> Enum.frequencies_by(& &1.type)
      |> Map.put("all", length(entries))

    shown =
      entries
      |> Enum.filter(&(socket.assigns.filter in ["all", &1.type]))
      |> Enum.sort_by(& &1.deleted_at, {:desc, DateTime})

    socket
    # Streams cannot be counted, so counts are kept beside them.
    |> assign(:counts, counts)
    |> assign(:shown, length(shown))
    |> stream(:entries, shown, reset: true)
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
        "#{format_date(invoice.invoice_date)} · #{rupees(invoice.grand_total || 0)} · #{invoice.status}",
      deleted_at: invoice.deleted_at,
      locked: nil,
      purge_confirm:
        "Permanently delete #{invoice.invoice_number}? Its line items, e-way bills and " <>
          "credit notes go with it. This cannot be undone, and the number is not reused."
    }
  end

  defp entry(%Client{} = client) do
    in_use? = Clients.in_use?(client)

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

  defp entry(%InvoiceTemplate{} = template) do
    in_use? = Templates.in_use?(template)

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

  def render(assigns) do
    assigns = assign(assigns, :filters, @filters)

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

      <div id="bin-filters" class="mb-4 flex flex-wrap items-center gap-2">
        <button
          :for={{key, label} <- @filters}
          type="button"
          id={"bin-filter-#{key}"}
          phx-click="filter"
          phx-value-type={key}
          aria-pressed={to_string(@filter == key)}
          class={[
            "inline-flex h-8 items-center gap-2 rounded-full border px-3 text-xs",
            "transition-colors duration-150",
            if(@filter == key,
              do: "border-base-content bg-base-content font-medium text-base-100",
              else:
                "border-base-300 bg-base-100 text-base-content/60 hover:bg-base-200 hover:text-base-content"
            )
          ]}
        >
          {label}
          <span
            id={"bin-count-#{key}"}
            class={[
              "rounded-full px-1.5 py-px text-2xs tabular-nums",
              if(@filter == key, do: "bg-base-100/20", else: "bg-base-200")
            ]}
          >
            {Map.get(@counts, key, 0)}
          </span>
        </button>
      </div>

      <.card class="flex flex-1 flex-col">
        <div :if={@shown == 0} id="bin-empty" class="flex flex-1 flex-col justify-center">
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
        <div class={[@shown == 0 && "hidden"]}>
          <table class="table table-fixed">
            <thead>
              <tr class={table_head_class()}>
                <th class="w-32">Type</th>

                <th>Item</th>

                <th>Details</th>

                <th class="w-36">Deleted on</th>

                <th class="w-64 text-right">Actions</th>
              </tr>
            </thead>

            <tbody id="bin-entries" phx-update="stream">
              <tr :for={{dom_id, entry} <- @streams.entries} id={dom_id} class={table_row_class()}>
                <td>
                  <span class="inline-flex items-center gap-1.5 rounded-full bg-base-200 px-2 py-0.5 text-xs text-base-content/70">
                    <.icon name={entry.icon} class="size-3.5" /> {entry.kind}
                  </span>
                </td>

                <td>
                  <p class="truncate font-medium">{entry.title}</p>

                  <p :if={entry.subtitle} class="truncate text-xs text-base-content/60">
                    {entry.subtitle}
                  </p>
                </td>

                <td class="truncate text-base-content/60">{entry.details}</td>

                <td class="text-base-content/60">
                  <p>{format_date(DateTime.to_date(entry.deleted_at))}</p>

                  <p class="text-xs text-base-content/45">{relative_time(entry.deleted_at)}</p>
                </td>

                <td>
                  <div class="flex items-center justify-end gap-1.5">
                    <button
                      type="button"
                      id={"bin-restore-#{entry.id}"}
                      phx-click="restore"
                      phx-value-type={entry.type}
                      phx-value-id={entry.record_id}
                      class={[secondary_button_class(), "h-8 px-2.5 text-xs"]}
                    >
                      <.icon name="hero-arrow-uturn-left" class="size-3.5" /> Restore
                    </button>

                    <button
                      :if={!entry.locked}
                      type="button"
                      id={"bin-purge-#{entry.id}"}
                      phx-click="purge"
                      phx-value-type={entry.type}
                      phx-value-id={entry.record_id}
                      data-confirm={entry.purge_confirm}
                      class={[
                        secondary_button_class(),
                        "h-8 px-2.5 text-xs text-error hover:border-error/40 hover:bg-error/10"
                      ]}
                    >
                      <.icon name="hero-trash" class="size-3.5" /> Delete permanently
                    </button>

                    <span
                      :if={entry.locked}
                      id={"bin-locked-#{entry.id}"}
                      title={entry.locked}
                      class="inline-flex h-8 items-center gap-1.5 px-2.5 text-xs text-base-content/45"
                    >
                      <.icon name="hero-lock-closed" class="size-3.5" /> In use
                    </span>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
