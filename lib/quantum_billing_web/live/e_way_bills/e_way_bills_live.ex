defmodule QuantumBillingWeb.EWayBillsLive do
  @moduledoc """
  The E-Way Bills list page: search, status filter, sortable columns and
  pagination over the issued consignment notes.

  Every one of those four happens in Postgres, through `EWayBills.page/1`, and
  only the ten rows on screen are ever loaded. The page used to hold every
  e-way bill in the system in the LiveView's memory — one copy per open browser
  tab — and filter, sort and slice them in Elixir on every keystroke.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.EWayBills

  @per_page 10

  def mount(_params, _session, socket) do
    if connected?(socket), do: EWayBills.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "E-Way Bills")
     |> assign(:active_nav, :e_way_bills)
     |> assign(:search, "")
     |> assign(:status_filter, "All Status")
     |> assign(:sort_field, :issued_on)
     |> assign(:sort_dir, :desc)
     |> assign(:page, 1)
     |> load_page()}
  end

  defp load_page(socket) do
    %{rows: rows, total: total, page: page, total_pages: total_pages} =
      EWayBills.page(
        search: socket.assigns.search,
        status: socket.assigns.status_filter,
        sort_field: socket.assigns.sort_field,
        sort_dir: socket.assigns.sort_dir,
        page: socket.assigns.page,
        per_page: @per_page
      )

    socket
    |> assign(:rows, rows)
    |> assign(:total, total)
    |> assign(:page, page)
    |> assign(:total_pages, total_pages)
    |> assign(:row_offset, (page - 1) * @per_page)
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> assign(:page, 1) |> load_page()}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status_filter, status) |> assign(:page, 1) |> load_page()}
  end

  def handle_event("sort", %{"field" => field_str}, socket) do
    field = sort_field(field_str) || socket.assigns.sort_field

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

  def handle_event("paginate", %{"page" => page_str}, socket) do
    {:noreply, socket |> assign(:page, String.to_integer(page_str)) |> load_page()}
  end

  def handle_info({:e_way_bill_changed, _bill}, socket) do
    {:noreply, load_page(socket)}
  end

  def render(assigns) do
    assigns = assign(assigns, :status_options, EWayBills.status_options())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        E-Way Bills
        <:subtitle>Track consignments and generate new e-way bills</:subtitle>

        <:actions>
          <.link navigate={~p"/e-way-bills/new"} class={action_button_class()}>
            <.icon name="hero-plus" class="size-4" /> Generate New E-Way Bill
          </.link>
        </:actions>
      </.header>

      <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <form
          id="ewb-search"
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
            placeholder="Search e-way bills..."
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

          <.link href={~p"/reports/export?report_type=E-Way+Bills"} class={filter_button_class()}>
            <.icon name="hero-arrow-down-tray" class="size-3.5" /> Export
          </.link>
        </div>
      </div>

      <.card class="flex flex-1 flex-col">
        <.empty_state
          :if={@total == 0}
          class="flex-1 justify-center"
          icon="hero-truck"
          title={
            if @search == "" and @status_filter == "All Status",
              do: "No e-way bills yet",
              else: "No e-way bills match these filters"
          }
          description={
            if @search == "" and @status_filter == "All Status",
              do: "Consignments you generate an e-way bill for will appear here.",
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
                    label="EWB No."
                    field={:ewb_no}
                  />
                </th>

                <th>Document No.</th>

                <th>
                  <.sortable_th
                    label="Issued On"
                    field={:issued_on}
                  />
                </th>

                <th>To</th>

                <th>Route</th>

                <th>
                  <.sortable_th
                    label="Value"
                    field={:value}
                  />
                </th>

                <th>Status</th>

                <th class="text-right">Actions</th>
              </tr>
            </thead>

            <tbody>
              <tr
                :for={{row, index} <- Enum.with_index(@rows)}
                id={"ewb-#{row.ewb_no}"}
                class={table_row_class()}
              >
                <td class="text-base-content/45">{@row_offset + index + 1}</td>

                <td class="font-medium">{row.ewb_no}</td>

                <td class="text-base-content/60">{row.document_no}</td>

                <td class="text-base-content/60">{format_date(row.issued_on)}</td>

                <td>{row.to_party}</td>

                <td class="text-base-content/60">{row.from_place} &rarr; {row.to_place}</td>

                <td class="font-medium">{rupees(row.value, decimals: 2, space: true)}</td>

                <td><.status_badge status={row.status} /></td>

                <td>
                  <div class="flex justify-end gap-1">
                    <.link
                      navigate={~p"/invoices?q=#{row.document_no}"}
                      class={row_action_class()}
                      aria-label="View e-way bill document"
                    >
                      <.icon name="hero-eye" class="size-4" />
                    </.link>

                    <.link
                      navigate={~p"/invoices?q=#{row.document_no}"}
                      class={row_action_class()}
                      aria-label="Print e-way bill document"
                    >
                      <.icon name="hero-printer" class="size-4" />
                    </.link>

                    <button type="button" class={row_action_class()} aria-label="More actions">
                      <.icon name="hero-ellipsis-vertical" class="size-4" />
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

  # Compared against the allowlist rather than turned into an atom first:
  # `String.to_existing_atom/1` raises on anything unrecognised, which is a
  # crashed page for a stale or hand-edited sort link.
  defp sort_field(field_str) do
    Enum.find(EWayBills.sortable_fields(), &(Atom.to_string(&1) == field_str))
  end
end
