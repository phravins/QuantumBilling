defmodule QuantumBillingWeb.InvoicesLive do
  @moduledoc """
  The Invoices list page: search, status filter, sortable columns, and
  pagination over the full set of GST invoices.

  Invoices come from `QuantumBilling.Invoices`, which has nothing to return
  until the multi-tenant Ecto schema lands. `mount/3` loads them once;
  `handle_event/3` only ever updates raw filter/sort/page state, and `render/1`
  re-derives the visible rows fresh on every render so there is a single source
  of truth. The search, sort and pagination code below is already correct at
  zero rows and needs no change when real records arrive.
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
     |> assign(:all_invoices, Invoices.list_invoices())
     |> assign(:search, "")
     |> assign(:status_filter, "All Status")
     |> assign(:sort_field, :invoice_date)
     |> assign(:sort_dir, :desc)
     |> assign(:page, 1)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> assign(:page, 1)}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status_filter, status) |> assign(:page, 1)}
  end

  def handle_event("sort", %{"field" => field_str}, socket) do
    field = String.to_existing_atom(field_str)

    {sort_field, sort_dir} =
      if socket.assigns.sort_field == field do
        {field, if(socket.assigns.sort_dir == :asc, do: :desc, else: :asc)}
      else
        {field, :asc}
      end

    {:noreply, assign(socket, sort_field: sort_field, sort_dir: sort_dir, page: 1)}
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    {:noreply, assign(socket, :page, String.to_integer(page_str))}
  end

  def handle_info({:invoice_changed, _invoice}, socket) do
    {:noreply, assign(socket, :all_invoices, Invoices.list_invoices())}
  end

  def render(assigns) do
    filtered =
      assigns.all_invoices
      |> filter_search(assigns.search)
      |> filter_status(assigns.status_filter)
      |> sort_rows(assigns.sort_field, assigns.sort_dir)

    total = length(filtered)
    total_pages = max(ceil(total / @per_page), 1)
    page = assigns.page |> max(1) |> min(total_pages)
    rows = Enum.slice(filtered, (page - 1) * @per_page, @per_page)
    range_start = if total == 0, do: 0, else: (page - 1) * @per_page + 1
    range_end = min(page * @per_page, total)

    assigns =
      assign(assigns,
        rows: rows,
        total: total,
        total_pages: total_pages,
        page: page,
        range_start: range_start,
        range_end: range_end,
        status_options: @status_options
      )

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

      <.card>
        <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <form
            id="invoice-search"
            phx-change="search"
            phx-submit="search"
            class="relative w-full sm:max-w-xs"
          >
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/45"
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
              <div tabindex="0" role="button" class={secondary_button_class()}>
                <.icon name="hero-funnel" class="size-4" />
                {@status_filter}
                <.icon name="hero-chevron-down" class="size-4" />
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

            <button type="button" class={secondary_button_class()}>
              <.icon name="hero-arrow-down-tray" class="size-4" /> Export
            </button>
          </div>
        </div>

        <.empty_state
          :if={@total == 0}
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

        <div :if={@total > 0} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr class={table_head_class()}>
                <th>
                  <.sortable_th
                    label="Invoice #"
                    field={:seq}
                    current_field={@sort_field}
                    current_dir={@sort_dir}
                  />
                </th>
                <th>Client</th>
                <th>
                  <.sortable_th
                    label="Invoice Date"
                    field={:invoice_date}
                    current_field={@sort_field}
                    current_dir={@sort_dir}
                  />
                </th>
                <th>
                  <.sortable_th
                    label="Due Date"
                    field={:due_date}
                    current_field={@sort_field}
                    current_dir={@sort_dir}
                  />
                </th>
                <th>Total Amount</th>
                <th>Status</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} id={"invoice-#{row.id}"} class={table_row_class()}>
                <td class="font-medium">{row.number}</td>
                <td>{row.client}</td>
                <td class="text-base-content/60">{format_date(row.invoice_date)}</td>
                <td class="text-base-content/60">{format_date(row.due_date)}</td>
                <td class="font-medium">{rupees(row.amount)}</td>
                <td><.status_badge status={row.status} /></td>
                <td>
                  <div class="flex gap-1">
                    <.link
                      navigate={~p"/invoices/#{row.id}"}
                      class={row_action_class()}
                      aria-label="View invoice"
                    >
                      <.icon name="hero-eye" class="size-4" />
                    </.link>
                    <button type="button" class={row_action_class()} aria-label="Edit invoice">
                      <.icon name="hero-pencil-square" class="size-4" />
                    </button>
                    <button type="button" class={row_action_class()} aria-label="More actions">
                      <.icon name="hero-ellipsis-vertical" class="size-4" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div
          :if={@total > 0}
          class="mt-4 flex flex-col items-center justify-between gap-3 sm:flex-row"
        >
          <span class="text-sm text-base-content/60">
            Showing {@range_start} to {@range_end} of {@total} entries
          </span>
          <.pagination current_page={@page} total_pages={@total_pages} />
        </div>
      </.card>
    </Layouts.app>
    """
  end

  defp filter_search(rows, ""), do: rows

  defp filter_search(rows, search) do
    needle = String.downcase(search)

    Enum.filter(rows, fn r ->
      String.contains?(String.downcase(r.number), needle) or
        String.contains?(String.downcase(r.client), needle)
    end)
  end

  defp filter_status(rows, "All Status"), do: rows
  defp filter_status(rows, status), do: Enum.filter(rows, &(&1.status == status))

  defp sort_rows(rows, :seq, dir), do: Enum.sort_by(rows, & &1.seq, dir)
  defp sort_rows(rows, :invoice_date, dir), do: Enum.sort_by(rows, & &1.invoice_date, {dir, Date})
  defp sort_rows(rows, :due_date, dir), do: Enum.sort_by(rows, & &1.due_date, {dir, Date})
end
