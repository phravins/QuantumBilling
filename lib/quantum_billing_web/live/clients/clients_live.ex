defmodule QuantumBillingWeb.ClientsLive do
  @moduledoc """
  The Clients list page: search, status filter, sortable columns, and
  pagination over the full client base.

  Clients come from `QuantumBilling.Clients`, which has nothing to return until
  the multi-tenant Ecto schema lands. `mount/3` loads them once;
  `handle_event/3` only ever updates raw filter/sort/page state, and `render/1`
  re-derives the visible rows fresh on every render so there is a single source
  of truth. The search, sort and pagination code below is already correct at
  zero rows and needs no change when real records arrive.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.ClientsComponents

  alias QuantumBilling.Clients

  @per_page 10

  @status_options ["All Status", "Active", "Inactive", "Blocked"]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Clients.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Clients")
     |> assign(:active_nav, :clients)
     |> assign(:search, "")
     |> assign(:status_filter, "All Status")
     |> assign(:sort_field, nil)
     |> assign(:sort_dir, :asc)
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
    # Matched against the context's allowlist rather than converted to an atom:
    # this is user input heading for an ORDER BY.
    case Enum.find(Clients.sortable_fields(), &(to_string(&1) == field_str)) do
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

  # Checked against the schema's own list rather than trusted, because the status arrives from a click; and read fresh by id
  # rather than taken from the rendered row, which may be a page old.
  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    with true <- status in Clients.statuses(),
         %{} = client <- Clients.get_client(id),
         {:ok, updated} <- Clients.update_client(client, %{"status" => status}) do
      {:noreply,
       socket
       |> put_flash(:info, "#{updated.name} is now #{String.downcase(status)}.")
       |> load_page()}
    else
      nil ->
        {:noreply, socket |> put_flash(:error, "That client no longer exists.") |> load_page()}

      false ->
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That client could not be updated. Open it and fix the highlighted fields."
         )}
    end
  end

  # Moves the client to the Bin rather than removing it: see
  # `Clients.delete_client/2`. Read fresh by id for the same reason as above.
  def handle_event("delete", %{"id" => id}, socket) do
    case Clients.get_client(id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "That client no longer exists.") |> load_page()}

      client ->
        case Clients.delete_client(client, user_id: socket.assigns.current_scope.user.id) do
          {:ok, client} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{client.name} moved to the Bin.")
             |> load_page()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "That client could not be deleted.")}
        end
    end
  end

  # A client added, edited, binned or restored in another window. The page is
  # re-read rather than the row spliced in: the active search, filter and sort
  # all have to agree with where — or whether — it belongs on this screen.
  def handle_info({event, _client}, socket)
      when event in [
             :client_created,
             :client_updated,
             :client_binned,
             :client_restored,
             :client_purged
           ] do
    {:noreply, load_page(socket)}
  end

  defp load_page(socket) do
    result =
      Clients.page(
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
        Clients
        <:subtitle>Manage your clients and their details</:subtitle>

        <:actions>
          <.link navigate={~p"/clients/new"} class={action_button_class()}>
            <.icon name="hero-plus" class="size-4" /> Add New Client
          </.link>
        </:actions>
      </.header>

      <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <form
          phx-change="search"
          phx-submit="search"
          id="clients-search"
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
            placeholder="Search clients..."
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

          <.link href={~p"/reports/export?report_type=Clients"} class={filter_button_class()}>
            <.icon name="hero-arrow-down-tray" class="size-3.5" /> Export
          </.link>
        </div>
      </div>

      <%!-- No `mt-4`: the toolbar's `mb-4` used to collapse into it, and inside
      a flex column the two would stack into a double gap instead. Stretches
      whether or not there are rows — a short table floating above a band of
      empty page reads just as unfinished as an empty one did. --%>
      <.card class="flex flex-1 flex-col">
        <.empty_state
          :if={@total == 0}
          class="flex-1 justify-center"
          icon="hero-users"
          title={
            if @search == "" and @status_filter == "All Status",
              do: "No clients yet",
              else: "No clients match these filters"
          }
          description={
            if @search == "" and @status_filter == "All Status",
              do: "Customers you invoice will appear here.",
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
                    label="Client Name"
                    field={:name}
                  />
                </th>

                <th>GSTIN</th>

                <th>Email</th>

                <th>Phone</th>

                <th>
                  <.sortable_th
                    label="Outstanding"
                    field={:outstanding}
                  />
                </th>

                <th>Status</th>

                <th class="text-right">Actions</th>
              </tr>
            </thead>

            <tbody>
              <tr
                :for={{row, index} <- Enum.with_index(@rows)}
                id={"client-#{row.id}"}
                class={table_row_class()}
              >
                <td class="text-base-content/45">{@row_offset + index + 1}</td>

                <td>
                  <div class="flex items-center gap-3">
                    <.client_avatar name={row.name} /> <span class="font-medium">{row.name}</span>
                  </div>
                </td>

                <td class="text-base-content/60">{row.gstin}</td>

                <td class="text-base-content/60">{row.email}</td>

                <td class="text-base-content/60">{row.phone}</td>

                <td class="font-medium">{rupees(row.outstanding, decimals: 2, space: true)}</td>

                <td><.status_badge status={row.status} /></td>

                <td>
                  <div class="flex justify-end gap-1">
                    <%!-- The client, not that client's invoices. The eye on a
                    directory row means "open this record" — it does on the
                    Invoices list — and pointing it at a filtered invoice
                    search both broke that and duplicated the "View invoices"
                    item in the menu beside it. --%>
                    <.link
                      id={"view-client-#{row.id}"}
                      navigate={~p"/clients/#{row.id}"}
                      class={row_action_class()}
                      aria-label={"View #{row.name}"}
                    >
                      <.icon name="hero-eye" class="size-4" />
                    </.link>

                    <%!-- `dropdown-top` from halfway down the page, so the menu
                    opens upward on the last rows instead of off the bottom of
                    a card that does not scroll. --%>
                    <div class={[
                      "dropdown dropdown-end",
                      index >= div(length(@rows), 2) && "dropdown-top"
                    ]}>
                      <div
                        tabindex="0"
                        role="button"
                        class={row_action_class()}
                        aria-label={"More actions for #{row.name}"}
                      >
                        <.icon name="hero-ellipsis-vertical" class="size-4" />
                      </div>

                      <ul
                        tabindex="0"
                        class="dropdown-content menu z-20 w-52 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
                      >
                        <li>
                          <.link navigate={~p"/clients/#{row.id}/edit"}>
                            <.icon name="hero-pencil-square" class="size-4" /> Edit client
                          </.link>
                        </li>

                        <li>
                          <.link navigate={~p"/invoices?q=#{row.name}"}>
                            <.icon name="hero-document-text" class="size-4" /> View invoices
                          </.link>
                        </li>

                        <li>
                          <.link navigate={~p"/invoices/new"}>
                            <.icon name="hero-plus" class="size-4" /> New invoice
                          </.link>
                        </li>

                        <li class="menu-title px-3 pt-2 text-xs">Status</li>

                        <li :for={status <- Clients.statuses()}>
                          <button
                            type="button"
                            phx-click="set_status"
                            phx-value-id={row.id}
                            phx-value-status={status}
                            disabled={row.status == status}
                            class={row.status == status && "text-base-content/45"}
                          >
                            <.icon
                              name={
                                if row.status == status,
                                  do: "hero-check-circle",
                                  else: "hero-arrow-right-circle"
                              }
                              class="size-4"
                            /> {status}
                          </button>
                        </li>
                      </ul>
                    </div>

                    <button
                      type="button"
                      id={"client-delete-#{row.id}"}
                      phx-click="delete"
                      phx-value-id={row.id}
                      data-confirm={"Move #{row.name} to the Bin? Its invoices are kept, and any recurring billing for it stops. It can be restored from the Bin."}
                      class={row_delete_class()}
                      aria-label={"Move #{row.name} to the Bin"}
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

        <%!-- `mt-auto` rather than a fixed margin: the card stretches to the
        page, so this pins the pager to the bottom of it instead of leaving it
        floating under the last row. --%>
        <div :if={@total > 0} class="mt-auto flex items-center justify-end pt-4">
          <.pagination current_page={@page} total_pages={@total_pages} />
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
