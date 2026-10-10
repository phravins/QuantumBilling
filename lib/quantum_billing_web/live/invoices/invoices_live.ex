defmodule QuantumBillingWeb.InvoicesLive do
  @moduledoc """
  The Invoices list page: search, status filter, sortable columns, and
  pagination.

  All four are the database's job — `QuantumBilling.Invoices.page/1` searches,
  filters, sorts, counts and slices in one query pair, and this LiveView holds
  only the controls and the ten rows on screen. It used to hold every invoice
  in the system and do the work in Elixir on every render, which meant one full
  copy of the invoice table per open tab and a full reload whenever anything
  changed anywhere in the application.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Invoices

  @per_page 10

  @status_options [
    "All Status",
    "E-Invoice Generated",
    "Pending E-Invoice",
    "Draft",
    "E-Invoice Failed",
    "Cancelled"
  ]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Invoices.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Invoices")
     |> assign(:active_nav, :invoices)
     |> assign(:search, "")
     |> assign(:status_filter, "All Status")
     |> assign(:sort_field, :invoice_date)
     |> assign(:sort_dir, :desc)
     |> assign(:page, 1)}
  end

  # Applies a search or status from the URL before the first render.
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:search, param(params, "q", socket.assigns.search))
     |> assign(:status_filter, status_param(params, socket.assigns.status_filter))
     |> assign(:page, 1)
     |> load_page()}
  end

  defp param(params, key, fallback) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _missing -> fallback
    end
  end

  # Allowlisted status.
  defp status_param(params, fallback) do
    case Map.get(params, "status") do
      status when status in @status_options -> status
      _unknown -> fallback
    end
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> assign(:page, 1) |> load_page()}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status_filter, status) |> assign(:page, 1) |> load_page()}
  end

  def handle_event("sort", %{"field" => field_str}, socket) do
    # Allowlisted: the sort field comes from the browser.
    case Enum.find(Invoices.sortable_fields(), &(to_string(&1) == field_str)) do
      nil ->
        {:noreply, socket}

      field ->
        {sort_field, sort_dir} =
          if socket.assigns.sort_field == field do
            {field, if(socket.assigns.sort_dir == :asc, do: :desc, else: :asc)}
          else
            {field, :asc}
          end

        {:noreply,
         socket
         |> assign(sort_field: sort_field, sort_dir: sort_dir, page: 1)
         |> load_page()}
    end
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page, ""} -> {:noreply, socket |> assign(:page, page) |> load_page()}
      _not_a_page -> {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Invoices.get_invoice(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That invoice no longer exists.")}

      invoice ->
        case Invoices.delete_invoice(invoice, user_id: socket.assigns.current_scope.user.id) do
          {:ok, invoice} ->
            {:noreply,
             socket
             |> put_flash(:info, "Invoice #{invoice.invoice_number} moved to the Bin.")
             |> load_page()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "That invoice could not be deleted.")}
        end
    end
  end

  def handle_info({:invoice_changed, _invoice}, socket) do
    {:noreply, load_page(socket)}
  end

  # The context clamps the page number, so deleting the last row stays on a real page.
  defp load_page(socket) do
    result =
      Invoices.page(
        search: socket.assigns.search,
        status: socket.assigns.status_filter,
        sort_field: socket.assigns.sort_field,
        sort_dir: socket.assigns.sort_dir,
        page: socket.assigns.page,
        per_page: @per_page
      )

    socket
    |> assign(:rows, result.rows)
    |> assign(:total, result.total)
    |> assign(:total_pages, result.total_pages)
    |> assign(:page, result.page)
    |> assign(:row_offset, (result.page - 1) * result.per_page)
  end

  def render(assigns) do
    assigns = assign(assigns, status_options: @status_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        Invoices
        <:subtitle>Manage and track all your GST invoices</:subtitle>

        <:actions>
          <.link navigate={~p"/invoices/new"} class={action_button_class()}>
            <.icon name="hero-plus" class="size-4" /> Create New GST Invoice
          </.link>
        </:actions>
      </.header>

      <div class="mb-2 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <form
          id="invoice-search"
          phx-change="search"
          phx-submit="search"
          class="relative w-full sm:max-w-xs"
        >
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-base-content/45"
          />
          <input
            type="text"
            name="q"
            value={@search}
            phx-debounce="300"
            placeholder="Search invoices..."
            class={filter_input_class()}
          />
        </form>

        <div class="flex items-center gap-2">
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class={filter_button_class()}>
              <.icon name="hero-funnel" class="size-3.5" /> {@status_filter}
              <.icon name="hero-chevron-down" class="size-3.5" />
            </div>

            <ul
              tabindex="0"
              class="dropdown-content menu z-10 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
            >
              <li :for={s <- @status_options}>
                <a phx-click="filter_status" phx-value-status={s}>{s}</a>
              </li>
            </ul>
          </div>

          <.link href={~p"/reports/export"} class={filter_button_class()}>
            <.icon name="hero-arrow-down-tray" class="size-3.5" /> Export
          </.link>
        </div>
      </div>

      <.card padding="px-3 pt-1 pb-2" class="flex flex-1 flex-col">
        <.empty_state
          :if={@total == 0}
          class="flex-1 justify-center"
          icon="hero-document-text"
          title={
            if @search == "" and @status_filter == "All Status",
              do: "No invoices yet",
              else: "No invoices match these filters"
          }
          description={
            if @search == "" and @status_filter == "All Status",
              do: "GST invoices you create will appear here.",
              else: "Try a different search term or status."
          }
        />
        <div :if={@total > 0}>
          <table class="table table-fixed">
            <thead>
              <tr class={table_head_class()}>
                <th class="w-12">S.No</th>

                <th class="w-32">
                  <.sortable_th
                    label="Invoice"
                    field={:seq}
                  />
                </th>

                <th>Client</th>

                <th class="w-32">
                  <.sortable_th
                    label="Invoice Date"
                    field={:invoice_date}
                  />
                </th>

                <th class="w-32">
                  <.sortable_th
                    label="Due Date"
                    field={:due_date}
                  />
                </th>

                <th class="w-36">Total Amount</th>

                <th class="w-44">Status</th>

                <th class="w-32">Actions</th>
              </tr>
            </thead>

            <tbody>
              <%!-- The serial continues across pages. --%>
              <tr
                :for={{row, index} <- Enum.with_index(@rows)}
                id={"invoice-#{row.id}"}
                class={table_row_class()}
              >
                <td class="whitespace-nowrap text-base-content/45 tabular-nums">
                  {@row_offset + index + 1}
                </td>

                <td class="truncate whitespace-nowrap font-medium">{row.number}</td>

                <td class="truncate whitespace-nowrap" title={row.client}>{row.client}</td>

                <td class="whitespace-nowrap text-base-content/60">
                  {format_date(row.invoice_date)}
                </td>

                <td class="whitespace-nowrap text-base-content/60">{format_date(row.due_date)}</td>

                <td class="whitespace-nowrap font-medium tabular-nums">
                  {rupees(row.amount)}
                </td>

                <td class="whitespace-nowrap"><.status_badge status={row.status} /></td>

                <td>
                  <div class="flex gap-1">
                    <.link
                      navigate={~p"/invoices/#{row.id}"}
                      class={row_action_class()}
                      aria-label="View invoice"
                    >
                      <.icon name="hero-eye" class="size-4" />
                    </.link>

                    <div class="dropdown dropdown-end">
                      <div
                        tabindex="0"
                        role="button"
                        class={row_action_class()}
                        aria-label="More actions"
                      >
                        <.icon name="hero-ellipsis-vertical" class="size-4" />
                      </div>

                      <ul
                        tabindex="0"
                        class="dropdown-content menu z-10 mt-1 w-48 rounded-box border border-base-300 bg-base-100 p-1.5 text-sm shadow-lg"
                      >
                        <li>
                          <.link navigate={~p"/invoices/#{row.id}/edit"}>
                            <.icon name="hero-pencil-square" class="size-4" /> Edit
                          </.link>
                        </li>

                        <li>
                          <%!-- Real navigation: the print view is a plain page. --%>
                          <.link href={~p"/invoices/#{row.id}/pdf/download"}>
                            <.icon name="hero-arrow-down-tray" class="size-4" /> Download as PDF
                          </.link>
                        </li>
                      </ul>
                    </div>

                    <button
                      type="button"
                      id={"invoice-delete-#{row.id}"}
                      phx-click="delete"
                      phx-value-id={row.id}
                      data-confirm={"Move #{row.number} to the Bin? It can be restored from there."}
                      class={row_delete_class()}
                      aria-label="Move invoice to the Bin"
                      title="Move to Bin"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@total > 0} class="mt-auto flex items-center justify-end pt-4">
          <.pagination current_page={@page} total_pages={@total_pages} />
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
