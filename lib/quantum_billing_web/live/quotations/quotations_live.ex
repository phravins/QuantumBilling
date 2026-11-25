defmodule QuantumBillingWeb.QuotationsLive do
  @moduledoc """
  The Quotations list: search, status tabs with counts (Expired included),
  sorting and pagination, all done in the database by `Quotations.page/1`.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Quotations
  alias QuantumBilling.Quotations.Quotation

  @per_page 10

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Quotations")
     |> assign(:active_nav, :quotations)
     |> assign(:search, "")
     |> assign(:status_filter, "All")
     |> assign(:sort_field, :quotation_date)
     |> assign(:sort_dir, :desc)
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> stream_configure(:quotations, dom_id: &"quotation-#{&1.id}")
     |> stream(:quotations, [])}
  end

  # Applies a search or status from the URL before the first render.
  def handle_params(params, _uri, socket) do
    status =
      case params["status"] do
        status when is_binary(status) -> if status in Quotation.filters(), do: status, else: "All"
        _missing -> socket.assigns.status_filter
      end

    {:noreply,
     socket
     |> assign(:search, if(is_binary(params["q"]), do: params["q"], else: socket.assigns.search))
     |> assign(:status_filter, status)
     |> assign(:page, 1)
     |> load_page()}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> assign(:page, 1) |> load_page()}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    # Allowlisted: the status comes from the browser.
    status = if status in Quotation.filters(), do: status, else: "All"
    {:noreply, socket |> assign(:status_filter, status) |> assign(:page, 1) |> load_page()}
  end

  def handle_event("sort", %{"field" => field_str}, socket) do
    case Enum.find(Quotations.sortable_fields(), &(to_string(&1) == field_str)) do
      nil ->
        {:noreply, socket}

      field ->
        dir =
          cond do
            socket.assigns.sort_field != field -> :asc
            socket.assigns.sort_dir == :asc -> :desc
            true -> :asc
          end

        {:noreply, socket |> assign(sort_field: field, sort_dir: dir, page: 1) |> load_page()}
    end
  end

  def handle_event("fit_rows", %{"rows" => rows}, socket) do
    case fit_rows_per_page(rows) do
      {:ok, per_page} when per_page != socket.assigns.per_page ->
        first_row = (socket.assigns.page - 1) * socket.assigns.per_page

        {:noreply,
         socket
         |> assign(per_page: per_page, page: div(first_row, per_page) + 1)
         |> load_page()}

      _unchanged_or_invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page, ""} -> {:noreply, socket |> assign(:page, page) |> load_page()}
      _not_a_page -> {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Quotation{} = quotation <- Quotations.get_quotation(id),
         {:ok, deleted} <- Quotations.delete_quotation(socket.assigns.current_scope, quotation) do
      {:noreply,
       socket
       |> put_flash(:info, "Quotation #{deleted.number} moved to the Bin.")
       |> load_page()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "That quotation no longer exists.")}

      {:error, :converted} ->
        {:noreply, put_flash(socket, :error, "A converted quotation is kept with its invoice.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That quotation could not be deleted.")}
    end
  end

  defp load_page(socket) do
    today = Quotations.today()

    result =
      Quotations.page(
        search: socket.assigns.search,
        status: socket.assigns.status_filter,
        today: today,
        sort_field: socket.assigns.sort_field,
        sort_dir: socket.assigns.sort_dir,
        page: socket.assigns.page,
        per_page: socket.assigns.per_page
      )

    socket
    |> assign(:today, today)
    |> assign(:counts, Quotations.status_counts(today))
    |> assign(:empty?, result.rows == [])
    |> assign(:has_next, result.has_next?)
    |> assign(:page, result.page)
    |> stream(:quotations, result.rows, reset: true)
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        tabs: ["All" | Quotation.filters()],
        filtered?: assigns.search != "" or assigns.status_filter != "All"
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        Quotations
        <:subtitle>Estimates you send before invoicing. They never count towards GST.</:subtitle>

        <:actions>
          <.link id="new-quotation" navigate={~p"/quotations/new"} class={action_button_class()}>
            <.icon name="hero-plus" class="size-4" /> New Quotation
          </.link>
        </:actions>
      </.header>

      <div class="mb-2 flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
        <form
          id="quotation-search"
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
            placeholder="Search number or client..."
            class={filter_input_class()}
          />
        </form>

        <div
          id="quotation-status-tabs"
          role="tablist"
          class="flex flex-wrap items-center gap-1 rounded-xl border border-base-300 bg-base-100 p-1"
        >
          <button
            :for={tab <- @tabs}
            id={"quotation-status-#{String.downcase(tab)}"}
            type="button"
            role="tab"
            aria-selected={to_string(@status_filter == tab)}
            phx-click="filter_status"
            phx-value-status={tab}
            class={[
              "inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1 text-xs font-medium transition-colors",
              if(@status_filter == tab,
                do: "bg-base-content text-base-100 shadow-sm",
                else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            {tab}
            <span class={[
              "rounded-full px-1.5 text-2xs tabular-nums",
              if(@status_filter == tab, do: "bg-base-100/20", else: "bg-base-200")
            ]}>
              {tab_count(@counts, tab)}
            </span>
          </button>
        </div>
      </div>

      <.card padding="px-3 pt-1 pb-2" class="flex flex-1 flex-col">
        <.empty_state
          :if={@empty?}
          class="flex-1 justify-center"
          icon="hero-clipboard-document-list"
          title={if @filtered?, do: "No quotations match", else: "No quotations yet"}
          description={
            if @filtered?,
              do: "Try a different search term or status.",
              else: "Quotations you create will appear here, ready to convert into invoices."
          }
        />

        <div :if={not @empty?} class="overflow-x-auto">
          <table class="table table-fixed min-w-[52rem]">
            <thead>
              <tr class={table_head_class()}>
                <th class="w-36"><.sortable_th label="Quotation" field={:number} /></th>
                <th><.sortable_th label="Client" field={:client} /></th>
                <th class="w-32"><.sortable_th label="Date" field={:quotation_date} /></th>
                <th class="w-32"><.sortable_th label="Valid Until" field={:valid_until} /></th>
                <th class="w-36"><.sortable_th label="Amount" field={:amount} /></th>
                <th class="w-36">Status</th>
                <th class="w-24">Actions</th>
              </tr>
            </thead>

            <tbody id="quotations" phx-update="stream">
              <tr
                :for={{dom_id, quotation} <- @streams.quotations}
                id={dom_id}
                class={table_row_class()}
              >
                <td class="truncate whitespace-nowrap font-medium">
                  <.link navigate={~p"/quotations/#{quotation}"} class="hover:underline">
                    {quotation.number}
                  </.link>
                </td>
                <td class="truncate whitespace-nowrap" title={quotation.client_name}>
                  {quotation.client_name}
                </td>
                <td class="whitespace-nowrap text-base-content/60">
                  {format_date(quotation.quotation_date)}
                </td>
                <td class="whitespace-nowrap text-base-content/60">
                  {format_date(quotation.valid_until)}
                </td>
                <td class="whitespace-nowrap font-medium tabular-nums">
                  {money(quotation.grand_total, quotation.currency)}
                </td>
                <td class="whitespace-nowrap">
                  <.status_badge status={Quotation.effective_status(quotation, @today)} />
                  <span
                    :if={Quotation.converted?(quotation)}
                    class="ml-1 inline-flex align-middle text-violet-600 dark:text-violet-400"
                    title={"Converted to #{quotation.invoice.invoice_number}"}
                  >
                    <.icon name="hero-arrow-right-circle" class="size-4" />
                  </span>
                </td>
                <td>
                  <div class="flex gap-1">
                    <.link
                      navigate={~p"/quotations/#{quotation}"}
                      class={row_action_class()}
                      aria-label="View quotation"
                    >
                      <.icon name="hero-eye" class="size-4" />
                    </.link>
                    <button
                      :if={not Quotation.converted?(quotation)}
                      type="button"
                      id={"quotation-delete-#{quotation.id}"}
                      phx-click="delete"
                      phx-value-id={quotation.id}
                      data-confirm={"Move #{quotation.number} to the Bin? It can be restored from there."}
                      class={row_delete_class()}
                      aria-label="Delete quotation"
                      title="Delete"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={not @empty?} class="mt-auto flex items-center justify-end pt-4">
          <.pagination current_page={@page} has_next={@has_next} fit_rows />
        </div>
      </.card>
    </Layouts.app>
    """
  end

  defp tab_count(counts, "All"), do: counts |> Map.values() |> Enum.sum()
  defp tab_count(counts, status), do: Map.get(counts, status, 0)
end
