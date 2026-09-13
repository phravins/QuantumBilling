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
     |> assign(:page, 1)
     |> load_page()}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> assign(:page, 1) |> load_page()}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status_filter, status) |> assign(:page, 1) |> load_page()}
  end

  def handle_event("sort", %{"field" => field_str}, socket) do
    # Matched against the context's allowlist rather than converted: a sort
    # field is user input on its way to an ORDER BY.
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
        # Already gone — most likely deleted in another window, whose broadcast
        # is about to refresh this list anyway.
        {:noreply, put_flash(socket, :error, "That invoice no longer exists.")}

      invoice ->
        case Invoices.delete_invoice(invoice) do
          {:ok, invoice} ->
            {:noreply,
             socket
             |> put_flash(:info, "Invoice #{invoice.invoice_number} deleted.")
             |> load_page()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "That invoice could not be deleted.")}
        end
    end
  end

  def handle_info({:invoice_changed, _invoice}, socket) do
    {:noreply, load_page(socket)}
  end

  # One query pair — a count and a page — per interaction. The page number is
  # re-clamped by the context, so deleting the last row of the last page lands
  # on a page that exists instead of an empty one.
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
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        Invoices
        <:subtitle>Manage and track all your GST invoices</:subtitle>

        <:actions>
          <.link navigate={~p"/invoices/new"} class={action_button_class()}>
            <.icon name="hero-plus" class="size-4" /> Create New GST Invoice
          </.link>
        </:actions>
      </.header>

      <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
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

      <.card class="flex flex-1 flex-col">
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

                <th>
                  <.sortable_th
                    label="Invoice"
                    field={:seq}
                  />
                </th>

                <th>Client</th>

                <th>
                  <.sortable_th
                    label="Invoice Date"
                    field={:invoice_date}
                  />
                </th>

                <th>
                  <.sortable_th
                    label="Due Date"
                    field={:due_date}
                  />
                </th>

                <th>Total Amount</th>

                <th>Status</th>

                <th class="text-right">Actions</th>
              </tr>
            </thead>

            <tbody>
              <%!-- The serial carries on across pages rather than restarting at
              1, so it reads as a position in the list, not on the screen. --%>
              <tr
                :for={{row, index} <- Enum.with_index(@rows)}
                id={"invoice-#{row.id}"}
                class={table_row_class()}
              >
                <td class="text-base-content/45">{@row_offset + index + 1}</td>

                <td class="font-medium">{row.number}</td>

                <td>{row.client}</td>

                <td class="text-base-content/60">{format_date(row.invoice_date)}</td>

                <td class="text-base-content/60">{format_date(row.due_date)}</td>

                <td class="font-medium">{rupees(row.amount)}</td>

                <td><.status_badge status={row.status} /></td>

                <td>
                  <div class="flex justify-end gap-1">
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
                          <%!-- A real navigation, not a LiveView event: the
                          print view is a plain page the browser has to load
                          before it can offer to save it. --%>
                          <.link href={~p"/invoices/#{row.id}/pdf"} target="_blank">
                            <.icon name="hero-arrow-down-tray" class="size-4" /> Download as PDF
                          </.link>
                        </li>

                        <li>
                          <a
                            phx-click="delete"
                            phx-value-id={row.id}
                            data-confirm={"Delete #{row.number}? This cannot be undone, and the number is not reused."}
                            class="text-error"
                          >
                            <.icon name="hero-trash" class="size-4" /> Delete
                          </a>
                        </li>
                      </ul>
                    </div>
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
