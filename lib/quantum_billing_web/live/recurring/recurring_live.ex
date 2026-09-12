defmodule QuantumBillingWeb.RecurringLive do
  @moduledoc """
  LiveView page for managing recurring invoice billing schedules.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Clients
  alias QuantumBilling.Recurring

  def mount(_params, _session, socket) do
    clients = Clients.list_clients()
    profiles = Recurring.list_profiles()

    changeset = Recurring.change_profile()

    {:ok,
     socket
     |> assign(:page_title, "Recurring Billing")
     |> assign(:active_nav, :recurring)
     |> assign(:clients, clients)
     |> assign(:profiles, profiles)
     |> assign(:form, to_form(changeset))
     |> assign(:show_modal, false)}
  end

  def handle_event("toggle_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, !socket.assigns.show_modal)}
  end

  def handle_event("save", %{"recurring_profile" => profile_params}, socket) do
    case Recurring.create_profile(profile_params) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Recurring billing profile created successfully!")
         |> assign(:profiles, Recurring.list_profiles())
         |> assign(:show_modal, false)
         |> assign(:form, to_form(Recurring.change_profile()))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    profile = Recurring.get_profile!(id)
    new_status = if profile.status == "Active", do: "Paused", else: "Active"

    {:ok, _updated} = Recurring.update_profile(profile, %{status: new_status})

    {:noreply,
     socket
     |> put_flash(:info, "Profile status updated to #{new_status}.")
     |> assign(:profiles, Recurring.list_profiles())}
  end

  def handle_event("run_now", _params, socket) do
    results = Recurring.process_due_profiles()
    count = length(results)

    {:noreply,
     socket
     |> put_flash(:info, "Processed #{count} due recurring invoice(s)!")
     |> assign(:profiles, Recurring.list_profiles())}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    profile = Recurring.get_profile!(id)
    {:ok, _} = Recurring.delete_profile(profile)

    {:noreply,
     socket
     |> put_flash(:info, "Recurring profile deleted.")
     |> assign(:profiles, Recurring.list_profiles())}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        Recurring Billing
        <:subtitle>Automate scheduled GST invoices for retainers and subscriptions</:subtitle>

        <:actions>
          <div class="flex items-center gap-2">
            <button
              type="button"
              phx-click="run_now"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-semibold shadow-sm transition"
            >
              <.icon name="hero-play" class="size-4" /> Run Pending Now
            </button>

            <button
              type="button"
              phx-click="toggle_modal"
              class={action_button_class()}
            >
              <.icon name="hero-plus" class="size-4" /> New Recurring Profile
            </button>
          </div>
        </:actions>
      </.header>

      <.card class="flex flex-1 flex-col">
        <.empty_state
          :if={@profiles == []}
          class="flex-1 justify-center"
          icon="hero-arrow-path"
          title="No recurring billing profiles yet"
          description="Create recurring profiles to automatically issue and email monthly or subscription GST invoices."
        />

        <div :if={@profiles != []}>
          <table class="table table-fixed">
            <thead>
              <tr class={table_head_class()}>
                <th>Profile Title</th>
                <th>Client</th>
                <th>Frequency</th>
                <th>Next Run Date</th>
                <th>Auto-Email PDF</th>
                <th>Status</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @profiles} id={"profile-#{p.id}"} class={table_row_class()}>
                <td class="font-medium">{p.title}</td>
                <td>{if p.client, do: p.client.name, else: "No Client"}</td>
                <td><span class="badge badge-ghost text-xs">{p.frequency}</span></td>
                <td class="font-mono text-xs">{p.next_run_date}</td>
                <td>
                  <span class={
                    if p.auto_send_email,
                      do: "text-emerald-500 font-semibold",
                      else: "text-base-content/40"
                  }>
                    {if p.auto_send_email, do: "Yes (PDF Attached)", else: "Disabled"}
                  </span>
                </td>
                <td>
                  <span class={
                    if p.status == "Active",
                      do: "badge badge-success text-xs",
                      else: "badge badge-warning text-xs"
                  }>
                    {p.status}
                  </span>
                </td>
                <td>
                  <div class="flex justify-end gap-2">
                    <button
                      type="button"
                      phx-click="toggle_status"
                      phx-value-id={p.id}
                      class="btn btn-xs btn-ghost"
                    >
                      {if p.status == "Active", do: "Pause", else: "Activate"}
                    </button>

                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-id={p.id}
                      data-confirm="Delete this recurring profile?"
                      class="btn btn-xs btn-ghost text-error"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>

      <%!-- Create Recurring Profile Modal --%>
      <div
        :if={@show_modal}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      >
        <div class="w-full max-w-lg rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl space-y-4">
          <div class="flex items-center justify-between border-b border-base-200 pb-3">
            <h3 class="text-base font-bold">New Recurring Billing Profile</h3>
            <button
              type="button"
              phx-click="toggle_modal"
              class="text-base-content/50 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <.form for={@form} id="recurring-profile-form" phx-submit="save" class="space-y-4">
            <div>
              <label class="block text-xs font-semibold mb-1">Profile Title</label>
              <.input
                field={@form[:title]}
                type="text"
                placeholder="e.g. Monthly IT Infrastructure Retainer"
                required
              />
            </div>

            <div>
              <label class="block text-xs font-semibold mb-1">Select Client</label>
              <select name={@form[:client_id].name} class="select select-bordered w-full text-xs">
                <option :for={c <- @clients} value={c.id}>
                  {c.name} ({c.gstin || "Unregistered"})
                </option>
              </select>
            </div>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-xs font-semibold mb-1">Frequency</label>
                <select name={@form[:frequency].name} class="select select-bordered w-full text-xs">
                  <option value="Monthly">Monthly</option>
                  <option value="Quarterly">Quarterly</option>
                  <option value="Annually">Annually</option>
                </select>
              </div>

              <div>
                <label class="block text-xs font-semibold mb-1">Start / Next Run Date</label>
                <.input
                  field={@form[:next_run_date]}
                  type="date"
                  value={to_string(Date.utc_today())}
                  required
                />
              </div>
            </div>

            <div class="flex items-center gap-2 pt-2">
              <input
                type="checkbox"
                name={@form[:auto_send_email].name}
                value="true"
                checked
                id="auto_email_cb"
                class="checkbox checkbox-primary checkbox-sm"
              />
              <label for="auto_email_cb" class="text-xs font-medium cursor-pointer">
                Automatically send PDF invoice to client's email address on generation
              </label>
            </div>

            <div class="flex justify-end gap-2 pt-4 border-t border-base-200">
              <button type="button" phx-click="toggle_modal" class="btn btn-sm btn-ghost">Cancel</button>
              <.button class="btn btn-sm btn-primary">Save Recurring Profile</.button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
