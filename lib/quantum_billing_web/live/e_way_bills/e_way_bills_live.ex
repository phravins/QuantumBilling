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
  alias QuantumBilling.EWayBills.EWayBill

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
     |> assign(:action, nil)
     |> assign(:action_bill, nil)
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

  def handle_event("open_action", %{"action" => action, "id" => id}, socket)
      when action in ["cancel", "part_b"] do
    case EWayBills.get_e_way_bill(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That e-way bill no longer exists.")}

      bill ->
        {:noreply,
         socket
         |> assign(:action, String.to_existing_atom(action))
         |> assign(:action_bill, bill)}
    end
  end

  def handle_event("close_action", _params, socket) do
    {:noreply, socket |> assign(:action, nil) |> assign(:action_bill, nil)}
  end

  def handle_event("cancel_bill", params, socket) do
    case with_fresh_bill(socket, &EWayBills.cancel_e_way_bill(&1, params)) do
      {:ok, cancelled} ->
        {:noreply,
         socket
         |> put_flash(:info, "E-way bill #{cancelled.ewb_number} cancelled.")
         |> assign(action: nil, action_bill: nil)
         |> load_page()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, cancel_error(reason))}
    end
  end

  def handle_event("update_part_b", params, socket) do
    case with_fresh_bill(socket, &EWayBills.update_part_b(&1, params)) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Vehicle updated: #{updated.ewb_number} is now on #{updated.vehicle_number}."
         )
         |> assign(action: nil, action_bill: nil)
         |> load_page()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, part_b_error(reason))}
    end
  end

  # Bins the bill; this is not a cancellation.
  def handle_event("delete", %{"id" => id}, socket) do
    case EWayBills.get_e_way_bill(id) do
      nil ->
        {:noreply,
         socket |> put_flash(:error, "That e-way bill no longer exists.") |> load_page()}

      bill ->
        case EWayBills.delete_e_way_bill(bill, user_id: socket.assigns.current_scope.user.id) do
          {:ok, bill} ->
            {:noreply,
             socket
             |> put_flash(:info, "E-way bill #{bill.ewb_number} moved to the Bin.")
             |> load_page()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "That e-way bill could not be deleted.")}
        end
    end
  end

  def handle_info({:e_way_bill_changed, _bill}, socket) do
    {:noreply, load_page(socket)}
  end

  # Re-read: the modal may hold a stale copy, and both actions depend on current state.
  defp with_fresh_bill(%{assigns: %{action_bill: nil}}, _action), do: {:error, :gone}

  defp with_fresh_bill(%{assigns: %{action_bill: bill}}, action) do
    case EWayBills.get_e_way_bill(bill.id) do
      nil -> {:error, :gone}
      fresh -> action.(fresh)
    end
  end

  defp delete_confirmation(%{status: "Active", ewb_no: number}) do
    "Move e-way bill #{number} to the Bin? This only takes it off this list — it is NOT " <>
      "cancelled on the e-way bill portal and stays valid there. It can be restored from the Bin."
  end

  defp delete_confirmation(%{ewb_no: number}) do
    "Move e-way bill #{number} to the Bin? It can be restored from there."
  end

  defp cancel_error(:gone), do: "That e-way bill no longer exists."
  defp cancel_error(:already_cancelled), do: "That e-way bill is already cancelled."

  defp cancel_error(:window_closed) do
    "Rule 138(9) allows cancellation only within #{EWayBills.cancellation_window_hours()} " <>
      "hours of generation. This bill is past that window and has to be cancelled on the " <>
      "NIC portal, or left to expire."
  end

  defp cancel_error(%Ecto.Changeset{}), do: "Enter a reason for the cancellation."
  defp cancel_error(reason), do: "The portal refused the cancellation: #{inspect(reason)}"

  defp part_b_error(:gone), do: "That e-way bill no longer exists."
  defp part_b_error(:already_cancelled), do: "A cancelled e-way bill cannot be updated."

  defp part_b_error(:expired),
    do: "This e-way bill has expired. The vehicle can only be updated while it is valid."

  defp part_b_error(%Ecto.Changeset{}), do: "Enter the new vehicle number."
  defp part_b_error(reason), do: "The portal refused the update: #{inspect(reason)}"

  def render(assigns) do
    assigns = assign(assigns, :status_options, EWayBills.status_options())

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        E-Way Bills
        <:subtitle>Track consignments and generate new e-way bills</:subtitle>

        <:actions>
          <.link navigate={~p"/e-way-bills/new"} class={action_button_class()}>
            <.icon name="hero-plus" class="size-4" /> Generate New E-Way Bill
          </.link>
        </:actions>
      </.header>

      <div class="mb-2 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
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

          <%!-- Carries the current filters so the export matches the table. --%>
          <.link
            href={~p"/e-way-bills/export?#{[q: @search, status: @status_filter]}"}
            class={filter_button_class()}
          >
            <.icon name="hero-arrow-down-tray" class="size-3.5" /> Export
          </.link>
        </div>
      </div>

      <.card padding="px-3 pt-1 pb-2" class="flex flex-1 flex-col">
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
          <table id="e-way-bills" class="table table-fixed">
            <thead>
              <tr class={table_head_class()}>
                <th class="w-12">S.No</th>

                <th class="w-36">
                  <.sortable_th
                    label="EWB No."
                    field={:ewb_no}
                  />
                </th>

                <th class="w-32">Document No.</th>

                <th class="w-28">
                  <.sortable_th
                    label="Issued On"
                    field={:issued_on}
                  />
                </th>

                <th>To</th>

                <th class="w-60">Route</th>

                <th class="w-32 text-right">
                  <.sortable_th
                    label="Value"
                    field={:value}
                  />
                </th>

                <th class="w-24">Status</th>

                <th class="w-52 text-right">Actions</th>
              </tr>
            </thead>

            <tbody>
              <tr
                :for={{row, index} <- Enum.with_index(@rows)}
                id={"ewb-#{row.ewb_no}"}
                class={table_row_class()}
              >
                <td class="whitespace-nowrap text-base-content/45 tabular-nums">
                  {@row_offset + index + 1}
                </td>

                <td class="truncate whitespace-nowrap font-medium tabular-nums">{row.ewb_no}</td>

                <td class="truncate whitespace-nowrap text-base-content/60" title={row.document_no}>
                  {row.document_no}
                </td>

                <td class="whitespace-nowrap text-base-content/60">{format_date(row.issued_on)}</td>

                <td class="truncate whitespace-nowrap" title={row.to_party}>{row.to_party}</td>

                <td
                  class="truncate whitespace-nowrap text-base-content/60"
                  title={"#{row.from_place} → #{row.to_place}"}
                >
                  {place_name(row.from_place)} &rarr; {place_name(row.to_place)}
                </td>

                <td class="whitespace-nowrap text-right font-medium tabular-nums">
                  {rupees(row.value, decimals: 2, space: true)}
                </td>

                <td class="whitespace-nowrap"><.status_badge status={row.status} /></td>

                <td>
                  <%!-- Open the official EWB-01 rendered by the controller. --%>
                  <div class="flex justify-end gap-1">
                    <.link
                      href={~p"/e-way-bills/#{row.id}/print"}
                      target="_blank"
                      class={row_action_class()}
                      aria-label={"View e-way bill #{row.ewb_no}"}
                    >
                      <.icon name="hero-eye" class="size-4" />
                    </.link>

                    <.link
                      href={~p"/e-way-bills/#{row.id}/print?print=1"}
                      target="_blank"
                      class={row_action_class()}
                      aria-label={"Print e-way bill #{row.ewb_no}"}
                    >
                      <.icon name="hero-printer" class="size-4" />
                    </.link>

                    <.link
                      href={~p"/e-way-bills/#{row.id}/print/download"}
                      class={row_action_class()}
                      aria-label={"Download e-way bill #{row.ewb_no} as PDF"}
                    >
                      <.icon name="hero-arrow-down-tray" class="size-4" />
                    </.link>

                    <%!-- Not offered once cancelled or expired: the portal refuses both. --%>
                    <button
                      :if={row.status == "Active"}
                      type="button"
                      phx-click="open_action"
                      phx-value-action="part_b"
                      phx-value-id={row.id}
                      class={row_action_class()}
                      aria-label={"Update vehicle for e-way bill #{row.ewb_no}"}
                    >
                      <.icon name="hero-truck" class="size-4" />
                    </button>

                    <button
                      :if={row.status == "Active" and row.cancellable}
                      type="button"
                      phx-click="open_action"
                      phx-value-action="cancel"
                      phx-value-id={row.id}
                      class={[row_action_class(), "hover:text-error"]}
                      aria-label={"Cancel e-way bill #{row.ewb_no}"}
                    >
                      <.icon name="hero-x-circle" class="size-4" />
                    </button>

                    <button
                      type="button"
                      id={"ewb-delete-#{row.id}"}
                      phx-click="delete"
                      phx-value-id={row.id}
                      data-confirm={delete_confirmation(row)}
                      class={row_delete_class()}
                      aria-label={"Move e-way bill #{row.ewb_no} to the Bin"}
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

      <.action_modal :if={@action == :cancel} bill={@action_bill} title="Cancel E-Way Bill">
        <form id="ewb-cancel-form" phx-submit="cancel_bill" class="space-y-3">
          <p class="text-xs text-base-content/70">
            Rule 138(9) allows cancellation within {EWayBills.cancellation_window_hours()} hours
            of generation, and only while the consignment has not been verified in transit. The
            number is spent: a replacement consignment needs a fresh e-way bill.
          </p>

          <div>
            <label for="ewb-cancel-reason" class="block text-xs font-semibold mb-1">
              Reason for cancellation
            </label>
            <select
              id="ewb-cancel-reason"
              name="cancellation_reason"
              class="select select-bordered w-full text-xs"
              required
            >
              <option value="Duplicate">Duplicate</option>
              <option value="Order Cancelled">Order cancelled</option>
              <option value="Data Entry Mistake">Data entry mistake</option>
              <option value="Others">Others</option>
            </select>
          </div>

          <div class="flex justify-end gap-2 border-t border-base-200 pt-3">
            <button type="button" phx-click="close_action" class={secondary_button_class()}>
              Keep it
            </button>
            <button type="submit" class="btn btn-sm btn-error">Cancel e-way bill</button>
          </div>
        </form>
      </.action_modal>

      <.action_modal :if={@action == :part_b} bill={@action_bill} title="Update Vehicle">
        <form id="ewb-part-b-form" phx-submit="update_part_b" class="space-y-3">
          <p class="text-xs text-base-content/70">
            Vehicle details are a record of every vehicle that carried the consignment, not a field that is
            overwritten. The new leg is added to the bill's history and the EWB-01 prints all of
            them.
          </p>

          <div>
            <label for="ewb-part-b-vehicle" class="block text-xs font-semibold mb-1">
              New vehicle number
            </label>
            <input
              id="ewb-part-b-vehicle"
              type="text"
              name="vehicle_number"
              placeholder="e.g. MH12AB1234"
              class="input input-bordered w-full text-xs uppercase"
              required
            />
          </div>

          <div>
            <label for="ewb-part-b-mode" class="block text-xs font-semibold mb-1">
              Mode of transport
            </label>
            <select
              id="ewb-part-b-mode"
              name="mode_of_transport"
              class="select select-bordered w-full text-xs"
            >
              <option
                :for={mode <- ~w(Road Rail Air Ship)}
                value={mode}
                selected={mode == @action_bill.mode_of_transport}
              >
                {mode}
              </option>
            </select>
          </div>

          <div>
            <label for="ewb-part-b-place" class="block text-xs font-semibold mb-1">
              Place of change
            </label>
            <input
              id="ewb-part-b-place"
              type="text"
              name="place"
              placeholder="Where the consignment changed vehicles"
              class="input input-bordered w-full text-xs"
            />
          </div>

          <div>
            <label for="ewb-part-b-reason" class="block text-xs font-semibold mb-1">Reason</label>
            <select
              id="ewb-part-b-reason"
              name="reason"
              class="select select-bordered w-full text-xs"
            >
              <option value="Transhipment">Transhipment</option>
              <option value="Breakdown">Breakdown</option>
              <option value="Accident">Accident</option>
              <option value="First Time">First time</option>
              <option value="Others">Others</option>
            </select>
          </div>

          <div class="flex justify-end gap-2 border-t border-base-200 pt-3">
            <button type="button" phx-click="close_action" class={secondary_button_class()}>
              Close
            </button>
            <button type="submit" class={action_button_class()}>Update Vehicle</button>
          </div>
        </form>
      </.action_modal>
    </Layouts.app>
    """
  end

  attr :bill, EWayBill, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp action_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div class="w-full max-w-md space-y-3 rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl">
        <div class="flex items-start justify-between border-b border-base-200 pb-3">
          <div>
            <h3 class="text-base font-bold">{@title}</h3>
            <p class="text-xs text-base-content/60">
              {@bill.ewb_number} &middot; {@bill.invoice.invoice_number}
            </p>
          </div>

          <button
            type="button"
            phx-click="close_action"
            class="text-base-content/50 hover:text-base-content"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # Allowlisted without String.to_existing_atom/1, which raises on stale links.
  defp sort_field(field_str) do
    Enum.find(EWayBills.sortable_fields(), &(Atom.to_string(&1) == field_str))
  end

  # "Maharashtra (27)" reads as "Maharashtra" in the list; the code stays in the tooltip.
  defp place_name(place) when is_binary(place), do: String.replace(place, ~r/\s*\(\d+\)\s*$/, "")
  defp place_name(place), do: place
end
