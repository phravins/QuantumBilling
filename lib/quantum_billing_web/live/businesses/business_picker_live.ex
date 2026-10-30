defmodule QuantumBillingWeb.BusinessPickerLive do
  @moduledoc """
  Every business the signed-in user belongs to, to choose which to work in.

  Where a user lands when they belong to several and have not chosen, and
  reachable from the top bar at any time. Choosing posts to
  `QuantumBillingWeb.BusinessController.switch/2`.

  Owners also rename and archive their businesses here, and restore archived
  ones. Each of those reloads the page, so the top bar's list of businesses —
  read once, when the page mounts — follows too.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Businesses
  alias QuantumBilling.Businesses.Business

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, "Businesses")
     |> assign(:active_nav, nil)
     |> assign(:entries, Businesses.list_for_user(user))
     |> assign(:archived, Businesses.list_archived_owned(user))
     |> assign(:can_create?, Businesses.owns_any?(user))
     |> assign(:renaming_id, nil)
     |> assign(:rename_form, nil)}
  end

  @impl true
  def handle_event("rename", %{"id" => id}, socket) do
    case owned(socket, id) do
      nil ->
        {:noreply, socket}

      business ->
        {:noreply,
         socket
         |> assign(:renaming_id, business.id)
         |> assign(:rename_form, to_form(Business.name_changeset(business, %{})))}
    end
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, renaming_id: nil, rename_form: nil)}
  end

  def handle_event("validate_rename", %{"business" => params}, socket) do
    case owned(socket, socket.assigns.renaming_id) do
      nil ->
        {:noreply, socket}

      business ->
        changeset = Business.name_changeset(business, params)
        {:noreply, assign(socket, :rename_form, to_form(changeset, action: :validate))}
    end
  end

  def handle_event("save_rename", %{"business" => params}, socket) do
    with %Business{} = business <- owned(socket, socket.assigns.renaming_id),
         {:ok, renamed} <- Businesses.rename(user(socket), business, params) do
      {:noreply, reload(socket, "Renamed to #{renamed.name}.")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :rename_form, to_form(changeset))}

      _not_owned ->
        {:noreply, socket}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    with %Business{} = business <- owned(socket, id),
         {:ok, archived} <- Businesses.archive(user(socket), business) do
      {:noreply, reload(socket, "#{archived.name} is archived. Its records are kept.")}
    else
      {:error, :first_business} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The first business cannot be archived: links and jobs from before there were several lead there."
         )}

      _not_owned ->
        {:noreply, socket}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    with %Business{} = business <-
           Enum.find(socket.assigns.archived, &(to_string(&1.id) == to_string(id))),
         {:ok, restored} <- Businesses.restore(user(socket), business) do
      {:noreply, reload(socket, "#{restored.name} is back.")}
    else
      _not_owned -> {:noreply, socket}
    end
  end

  # Only the user's own active businesses, and only those they own: an id from
  # the client is a lookup key, never a permission.
  defp owned(socket, id) do
    Enum.find_value(socket.assigns.entries, fn {business, membership} ->
      if to_string(business.id) == to_string(id) and membership.role == "owner", do: business
    end)
  end

  defp user(socket), do: socket.assigns.current_scope.user

  defp reload(socket, message) do
    socket
    |> put_flash(:info, message)
    |> push_navigate(to: ~p"/businesses")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div class="mx-auto w-full max-w-3xl py-6">
        <.header>
          Your businesses
          <:subtitle>Each keeps its own clients, invoices, numbering and settings.</:subtitle>
          <:actions>
            <.link
              :if={@can_create?}
              navigate={~p"/businesses/new"}
              id="picker-new-business"
              class={action_button_class()}
            >
              <.icon name="hero-plus" class="size-4" /> New business
            </.link>
          </:actions>
        </.header>

        <.card :if={@entries == []} id="no-businesses">
          <.empty_state
            icon="hero-building-office-2"
            title="You are not part of any business yet"
            description="Ask an owner to add you to their business. You will see it here as soon as they do."
          />
        </.card>

        <ul :if={@entries != []} id="business-list" class="grid gap-2.5 sm:grid-cols-2">
          <li
            :for={{business, membership} <- @entries}
            id={"business-#{business.id}"}
            class={[
              "group/card rounded-box border bg-base-100 transition-all duration-150",
              "hover:-translate-y-0.5 hover:shadow-md",
              if(current?(@current_scope, business),
                do: "border-primary/50 ring-1 ring-primary/20",
                else: "border-base-300 hover:border-base-content/20"
              )
            ]}
          >
            <%= if @renaming_id == business.id do %>
              <.form
                for={@rename_form}
                id={"rename-business-#{business.id}"}
                phx-change="validate_rename"
                phx-submit="save_rename"
                class="p-4"
              >
                <.input field={@rename_form[:name]} type="text" label="Name" phx-mounted={JS.focus()} />
                <p class="-mt-1 text-xs text-base-content/55">
                  Payment links keep working: they use <span class="font-mono">{business.slug}</span>, which does not change.
                </p>
                <div class="mt-3 flex justify-end gap-2">
                  <button
                    type="button"
                    id={"cancel-rename-#{business.id}"}
                    phx-click="cancel_rename"
                    class={secondary_button_class()}
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    id={"save-rename-#{business.id}"}
                    phx-disable-with="Saving…"
                    class={action_button_class()}
                  >
                    Save
                  </button>
                </div>
              </.form>
            <% else %>
              <.link
                href={~p"/businesses/#{business.id}/switch"}
                method="post"
                id={"choose-business-#{business.id}"}
                class="group flex items-center gap-3 p-4"
              >
                <span class="flex size-10 shrink-0 items-center justify-center rounded-field bg-base-200 text-sm font-semibold text-base-content/70 transition-colors group-hover:bg-primary/10 group-hover:text-primary">
                  {initials(business.name)}
                </span>

                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-semibold tracking-tight">
                    {business.name}
                  </span>
                  <span class="mt-0.5 block text-xs text-base-content/55">
                    {if membership.role == "owner", do: "Owner", else: "Staff"}
                    <span :if={current?(@current_scope, business)}>· Current</span>
                  </span>
                </span>

                <.icon
                  name="hero-arrow-right"
                  class="size-4 shrink-0 text-base-content/30 transition-transform group-hover:translate-x-0.5 group-hover:text-base-content/60"
                />
              </.link>

              <div
                :if={membership.role == "owner"}
                class="flex items-center justify-end gap-1 border-t border-base-200 px-3 py-1.5"
              >
                <button
                  type="button"
                  id={"rename-#{business.id}"}
                  phx-click="rename"
                  phx-value-id={business.id}
                  class="inline-flex items-center gap-1 rounded-field px-2 py-1 text-xs text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
                >
                  <.icon name="hero-pencil-square" class="size-3.5" /> Rename
                </button>
                <button
                  :if={business.id != 1}
                  type="button"
                  id={"archive-#{business.id}"}
                  phx-click="archive"
                  phx-value-id={business.id}
                  data-confirm={"Archive #{business.name}? It leaves this list and stops its scheduled jobs. Its records are kept, and you can restore it."}
                  class="inline-flex items-center gap-1 rounded-field px-2 py-1 text-xs text-base-content/60 transition-colors hover:bg-error/10 hover:text-error"
                >
                  <.icon name="hero-archive-box" class="size-3.5" /> Archive
                </button>
              </div>
            <% end %>
          </li>
        </ul>

        <section :if={@archived != []} id="archived-businesses" class="mt-8">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            Archived
          </h2>
          <ul class="mt-2 divide-y divide-base-200 rounded-box border border-base-300 bg-base-100">
            <li
              :for={business <- @archived}
              id={"archived-business-#{business.id}"}
              class="flex items-center gap-3 px-4 py-3"
            >
              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm font-medium text-base-content/70">
                  {business.name}
                </span>
                <span class="text-xs text-base-content/45">
                  Archived {Calendar.strftime(business.archived_at, "%d %b %Y")}
                </span>
              </span>
              <button
                type="button"
                id={"restore-#{business.id}"}
                phx-click="restore"
                phx-value-id={business.id}
                phx-disable-with="Restoring…"
                class={secondary_button_class()}
              >
                <.icon name="hero-arrow-uturn-left" class="size-4" /> Restore
              </button>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp current?(%{business: %{id: id}}, %{id: id}), do: true
  defp current?(_scope, _business), do: false

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end
end
