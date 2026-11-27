defmodule QuantumBillingWeb.EWayBillsLive do
  @moduledoc """
  The E-Way Bills list: search, status filter, sorting and pagination, all in
  the database via `EWayBills.page/1`. Only the visible rows are loaded.
  """
  use QuantumBillingWeb, :live_view

  on_mount {QuantumBillingWeb.GSTOnly, :e_way_bills}

  alias QuantumBilling.EWayBills
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.EWayBillExtension
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.EWayBills.Validity

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
     |> assign(:per_page, @per_page)
     |> assign(:action, nil)
     |> assign(:action_bill, nil)
     |> load_page()}
  end

  defp load_page(socket) do
    %{rows: rows, page: page, has_next?: has_next} =
      EWayBills.page(
        search: socket.assigns.search,
        status: socket.assigns.status_filter,
        sort_field: socket.assigns.sort_field,
        sort_dir: socket.assigns.sort_dir,
        page: socket.assigns.page,
        per_page: socket.assigns.per_page
      )

    socket
    |> assign(:rows, rows)
    |> assign(:empty?, rows == [])
    |> assign(:page, page)
    |> assign(:has_next, has_next)
    |> assign(:row_offset, (page - 1) * socket.assigns.per_page)
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

  # The pager's measured fit; keeps the row at the top of the current page on screen.
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
    {:noreply, socket |> assign(:page, String.to_integer(page_str)) |> load_page()}
  end

  def handle_event("open_action", %{"action" => action, "id" => id}, socket)
      when action in ["cancel", "part_b", "extend"] do
    case EWayBills.get_e_way_bill(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That e-way bill no longer exists.")}

      %{invoice: %{status: "Cancelled"}} when action == "extend" ->
        {:noreply, refuse_cancelled_extension(socket)}

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

  def handle_event("extend_validity", params, socket) do
    case with_fresh_bill(socket, &EWayBills.extend_validity(&1, params)) do
      {:ok, extended} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "E-way bill #{extended.ewb_number} extended: valid until " <>
             "#{format_ist(extended.valid_until)} IST."
         )
         |> assign(action: nil, action_bill: nil)
         |> load_page()}

      {:error, :cancelled} ->
        {:noreply, refuse_cancelled_extension(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, extend_error(reason))}
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

  defp refuse_cancelled_extension(socket) do
    socket
    |> assign(action: nil, action_bill: nil)
    |> put_flash(:error, "An e-way bill for a cancelled invoice cannot be extended.")
    |> load_page()
  end

  defp extend_error(:gone), do: "That e-way bill no longer exists."
  defp extend_error(:already_cancelled), do: "A cancelled e-way bill cannot be extended."

  defp extend_error(:replaced),
    do: "A newer e-way bill has replaced this one, so it can no longer be extended."

  defp extend_error(:outside_extension_window) do
    hours = Validity.extension_window_hours()

    "Rule 138(10) allows an extension only from #{hours} hours before to #{hours} hours " <>
      "after the bill expires."
  end

  defp extend_error(%Ecto.Changeset{} = changeset), do: changeset_error(changeset)

  defp extend_error(reason) do
    NICClient.error_message(reason) ||
      "The extension failed: #{QuantumBilling.ErrorMessages.text(reason)}"
  end

  # The first field error, in words: "Remaining distance (km) must be greater than 0".
  defp changeset_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, &interpolate/1) |> Enum.sort() do
      [{field, [message | _]} | _] -> "#{Phoenix.Naming.humanize(field)} #{message}."
      [] -> "Please check the details and try again."
    end
  end

  defp interpolate({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp format_ist(%NaiveDateTime{} = valid_until),
    do: valid_until |> Validity.to_ist() |> Calendar.strftime("%d/%m/%Y %I:%M %p")

  defp cancel_error(:gone), do: "That e-way bill no longer exists."
  defp cancel_error(:already_cancelled), do: "That e-way bill is already cancelled."

  defp cancel_error(:window_closed) do
    "Rule 138(9) allows cancellation only within #{EWayBills.cancellation_window_hours()} " <>
      "hours of generation. This bill is past that window and has to be cancelled on the " <>
      "NIC portal, or left to expire."
  end

  defp cancel_error(%Ecto.Changeset{}), do: "Enter a reason for the cancellation."

  defp cancel_error(reason) do
    NICClient.error_message(reason) ||
      "The cancellation failed: #{QuantumBilling.ErrorMessages.text(reason)}"
  end

  defp part_b_error(:gone), do: "That e-way bill no longer exists."
  defp part_b_error(:already_cancelled), do: "A cancelled e-way bill cannot be updated."

  defp part_b_error(:expired),
    do: "This e-way bill has expired. The vehicle can only be updated while it is valid."

  defp part_b_error(%Ecto.Changeset{} = changeset), do: changeset_error(changeset)

  defp part_b_error(reason) do
    NICClient.error_message(reason) ||
      "The update failed: #{QuantumBilling.ErrorMessages.text(reason)}"
  end

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
          <.action_menu
            id="e-way-bill-status-filter"
            label="Filter e-way bills by status"
            trigger_class={filter_button_class()}
            menu_class="z-10 mt-2 w-56"
          >
            <:trigger>
              <.icon name="hero-funnel" class="size-3.5" /> {@status_filter}
              <.icon name="hero-chevron-down" class="size-3.5" />
            </:trigger>
            <li :for={s <- @status_options}>
              <button
                type="button"
                role="menuitem"
                class="w-full rounded-field px-3 py-2 text-left hover:bg-base-200"
                phx-click="filter_status"
                phx-value-status={s}
              >
                {s}
              </button>
            </li>
          </.action_menu>

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
          :if={@empty?}
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
        <div :if={not @empty?}>
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

                <th class="w-32">
                  <.sortable_th
                    label="Value"
                    field={:value}
                  />
                </th>

                <th class="w-28">Status</th>

                <th class="w-52">Actions</th>
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

                <td class="truncate whitespace-nowrap font-medium tabular-nums">
                  {row.ewb_no}
                  <.portal_mode_badge
                    :if={row.portal_mode != "live"}
                    id={"ewb-mode-#{row.id}"}
                    mode={row.portal_mode}
                    compact
                  />
                </td>

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

                <td class="whitespace-nowrap font-medium tabular-nums">
                  {rupees(row.value, decimals: 2, space: true)}
                </td>

                <td class="whitespace-nowrap"><.status_badge status={row.status} /></td>

                <td>
                  <%!-- Open the official EWB-01 rendered by the controller. --%>
                  <div class="flex gap-1">
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

                    <%!-- Rule 138(10): from 8 hours before to 8 hours after expiry. --%>
                    <button
                      :if={row.extendable}
                      type="button"
                      phx-click="open_action"
                      phx-value-action="extend"
                      phx-value-id={row.id}
                      class={row_action_class()}
                      aria-label={"Extend validity of e-way bill #{row.ewb_no}"}
                    >
                      <.icon name="hero-clock" class="size-4" />
                    </button>

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

        <div :if={not @empty?} class="mt-auto flex items-center justify-end pt-4">
          <.pagination current_page={@page} has_next={@has_next} fit_rows />
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
            <button type="submit" phx-disable-with="Cancelling…" class="btn btn-sm btn-error">Cancel e-way bill</button>
          </div>
        </form>
      </.action_modal>

      <.action_modal :if={@action == :part_b} bill={@action_bill} title="Update Vehicle">
        <form id="ewb-part-b-form" phx-submit="update_part_b" class="space-y-3">
          <p class="text-xs text-base-content/70">
            Road needs the vehicle number; Rail, Air and Ship need the railway receipt, airway
            bill or bill of lading number and date. Vehicle details are a record of every vehicle that carried the consignment, not a field that is
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
              placeholder="e.g. MH12AB1234 (required for Road)"
              class="input input-bordered w-full text-xs uppercase"
            />
          </div>

          <.transport_document_inputs id="ewb-part-b" />

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
            <button type="submit" phx-disable-with="Updating…" class={action_button_class()}>Update Vehicle</button>
          </div>
        </form>
      </.action_modal>

      <.action_modal :if={@action == :extend} bill={@action_bill} title="Extend Validity">
        <form id="ewb-extend-form" phx-submit="extend_validity" class="space-y-3">
          <p class="text-xs text-base-content/70">
            Rule 138(10): a bill can be extended from {Validity.extension_window_hours()} hours
            before to {Validity.extension_window_hours()} hours after it expires, when the goods
            have not reached their destination. Valid until {format_ist(@action_bill.valid_until)} IST.
          </p>

          <div class="grid grid-cols-2 gap-3">
            <div>
              <label for="ewb-extend-reason" class="block text-xs font-semibold mb-1">Reason</label>
              <select
                id="ewb-extend-reason"
                name="reason"
                class="select select-bordered w-full text-xs"
              >
                <option :for={reason <- NICClient.extension_reasons()} value={reason}>
                  {reason}
                </option>
              </select>
            </div>
            <div>
              <label for="ewb-extend-distance" class="block text-xs font-semibold mb-1">
                Remaining distance (km)
              </label>
              <input
                id="ewb-extend-distance"
                type="number"
                min="1"
                max="4000"
                name="remaining_distance_km"
                class="input input-bordered w-full text-xs"
                required
              />
            </div>
          </div>

          <div>
            <label for="ewb-extend-remarks" class="block text-xs font-semibold mb-1">Remarks</label>
            <input
              id="ewb-extend-remarks"
              type="text"
              name="remarks"
              maxlength="50"
              class="input input-bordered w-full text-xs"
              required
            />
          </div>

          <div class="grid grid-cols-3 gap-3">
            <div>
              <label for="ewb-extend-place" class="block text-xs font-semibold mb-1">
                Current place
              </label>
              <input
                id="ewb-extend-place"
                type="text"
                name="from_place"
                class="input input-bordered w-full text-xs"
                required
              />
            </div>
            <div>
              <label for="ewb-extend-state" class="block text-xs font-semibold mb-1">State</label>
              <select
                id="ewb-extend-state"
                name="from_state"
                class="select select-bordered w-full text-xs"
              >
                <option :for={state <- EWayBillForm.states()} value={state}>{state}</option>
              </select>
            </div>
            <div>
              <label for="ewb-extend-pincode" class="block text-xs font-semibold mb-1">PIN code</label>
              <input
                id="ewb-extend-pincode"
                type="text"
                inputmode="numeric"
                name="from_pincode"
                maxlength="6"
                class="input input-bordered w-full text-xs"
                required
              />
            </div>
          </div>

          <div>
            <label for="ewb-extend-status" class="block text-xs font-semibold mb-1">
              Consignment
            </label>
            <select
              id="ewb-extend-status"
              name="consignment_status"
              class="select select-bordered w-full text-xs"
            >
              <option value="In Movement">In movement (on a vehicle or with a carrier)</option>
              <option value="In Transit">In transit (waiting at a place)</option>
            </select>
          </div>

          <fieldset class="space-y-3 rounded-lg border border-base-200 p-3">
            <legend class="px-1 text-xs font-semibold">If in movement</legend>
            <div class="grid grid-cols-2 gap-3">
              <div>
                <label for="ewb-extend-mode" class="block text-xs font-semibold mb-1">
                  Mode of transport
                </label>
                <select
                  id="ewb-extend-mode"
                  name="mode_of_transport"
                  class="select select-bordered w-full text-xs"
                >
                  <option
                    :for={mode <- EWayBill.transport_modes()}
                    value={mode}
                    selected={mode == @action_bill.mode_of_transport}
                  >
                    {mode}
                  </option>
                </select>
              </div>
              <div>
                <label for="ewb-extend-vehicle" class="block text-xs font-semibold mb-1">
                  Vehicle number
                </label>
                <input
                  id="ewb-extend-vehicle"
                  type="text"
                  name="vehicle_number"
                  value={@action_bill.vehicle_number}
                  class="input input-bordered w-full text-xs uppercase"
                />
              </div>
            </div>
            <.transport_document_inputs id="ewb-extend" />
          </fieldset>

          <fieldset class="space-y-3 rounded-lg border border-base-200 p-3">
            <legend class="px-1 text-xs font-semibold">If in transit</legend>
            <div class="grid grid-cols-3 gap-3">
              <div>
                <label for="ewb-extend-transit" class="block text-xs font-semibold mb-1">Where</label>
                <select
                  id="ewb-extend-transit"
                  name="transit_type"
                  class="select select-bordered w-full text-xs"
                >
                  <option :for={type <- EWayBillExtension.transit_types()} value={type}>
                    {type}
                  </option>
                </select>
              </div>
              <div class="col-span-2">
                <label for="ewb-extend-address" class="block text-xs font-semibold mb-1">
                  Address
                </label>
                <input
                  id="ewb-extend-address"
                  type="text"
                  name="address"
                  maxlength="120"
                  class="input input-bordered w-full text-xs"
                />
              </div>
            </div>
          </fieldset>

          <div class="flex justify-end gap-2 border-t border-base-200 pt-3">
            <button type="button" phx-click="close_action" class={secondary_button_class()}>
              Close
            </button>
            <button type="submit" phx-disable-with="Extending…" class={action_button_class()}>
              Extend Validity
            </button>
          </div>
        </form>
      </.action_modal>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true

  # Railway receipt, airway bill or bill of lading: required for Rail, Air and Ship.
  defp transport_document_inputs(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3">
      <div>
        <label for={"#{@id}-document-number"} class="block text-xs font-semibold mb-1">
          Transport document no.
        </label>
        <input
          id={"#{@id}-document-number"}
          type="text"
          name="transport_document_number"
          maxlength="15"
          placeholder="RR / AWB / BOL number"
          class="input input-bordered w-full text-xs"
        />
      </div>
      <div>
        <label for={"#{@id}-document-date"} class="block text-xs font-semibold mb-1">
          Transport document date
        </label>
        <input
          id={"#{@id}-document-date"}
          type="date"
          name="transport_document_date"
          class="input input-bordered w-full text-xs"
        />
      </div>
    </div>
    """
  end

  attr :bill, EWayBill, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp action_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <%!-- Capped to the viewport: the extension form is taller than a phone screen. --%>
      <div class="w-full max-w-md max-h-[90vh] space-y-3 overflow-y-auto rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl">
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
