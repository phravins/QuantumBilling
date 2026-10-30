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
      <div
        id="business-picker"
        class="flex min-h-[calc(100dvh-9rem)] w-full flex-col items-center justify-center py-8"
      >
        <div class="w-full max-w-5xl">
          <header class="mb-8 text-center">
            <span class="mx-auto mb-4 flex size-12 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-building-office-2" class="size-6" />
            </span>
            <h1 id="picker-welcome" class="text-2xl font-semibold tracking-tight sm:text-3xl">
              {welcome(@current_scope.user)}
            </h1>
            <p id="picker-count" class="mt-2 text-sm text-base-content/60">
              {count_line(length(@entries))}
            </p>
          </header>

          <div
            :if={@entries == [] and not @can_create?}
            id="no-businesses"
            class="mx-auto max-w-md rounded-2xl border border-dashed border-base-300 bg-base-100 p-8"
          >
            <.empty_state
              icon="hero-building-office-2"
              title="You are not part of any business yet"
              description="Ask an owner to add you to their business. You will see it here as soon as they do."
            />
          </div>

          <ul
            :if={@entries != [] or @can_create?}
            id="business-list"
            class={[
              "grid grid-cols-1 gap-4 sm:grid-cols-2",
              card_count(@entries, @can_create?) >= 3 && "lg:grid-cols-3",
              card_count(@entries, @can_create?) == 1 && "mx-auto max-w-sm sm:grid-cols-1"
            ]}
          >
            <li
              :for={{business, membership} <- @entries}
              id={"business-#{business.id}"}
              class={[
                "group/card flex min-h-44 flex-col overflow-hidden rounded-2xl border bg-base-100",
                "shadow-sm transition-all duration-200 motion-reduce:transition-none",
                "hover:-translate-y-0.5 hover:shadow-lg focus-within:shadow-lg motion-reduce:hover:translate-y-0",
                if(current?(@current_scope, business),
                  do: "border-primary/60 ring-1 ring-primary/25",
                  else: "border-base-300 hover:border-base-content/25"
                )
              ]}
            >
              <%= if @renaming_id == business.id do %>
                <.form
                  for={@rename_form}
                  id={"rename-business-#{business.id}"}
                  phx-change="validate_rename"
                  phx-submit="save_rename"
                  class="flex flex-1 flex-col p-5"
                >
                  <.input
                    field={@rename_form[:name]}
                    type="text"
                    label="Name"
                    phx-mounted={JS.focus()}
                  />
                  <p class="-mt-1 text-xs text-base-content/55">
                    Payment links keep working: they use <span class="font-mono">{business.slug}</span>, which does not change.
                  </p>
                  <div class="mt-auto flex justify-end gap-2 pt-3">
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
                  class="group flex flex-1 flex-col gap-4 p-5 outline-none focus-visible:bg-base-200/60"
                >
                  <span class="flex items-start justify-between gap-3">
                    <span class={[
                      "flex size-12 shrink-0 items-center justify-center rounded-xl text-base font-semibold",
                      tile_tone(business.id)
                    ]}>
                      {initials(business.name)}
                    </span>

                    <span class="flex flex-wrap justify-end gap-1.5">
                      <span
                        :if={current?(@current_scope, business)}
                        class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary"
                      >
                        <.icon name="hero-check" class="size-3" /> Current
                      </span>
                      <span class="inline-flex items-center rounded-full border border-base-300 px-2 py-0.5 text-xs font-medium text-base-content/70">
                        {if membership.role == "owner", do: "Owner", else: "Staff"}
                      </span>
                    </span>
                  </span>

                  <span class="min-w-0">
                    <span class="block truncate text-base font-semibold tracking-tight">
                      {business.name}
                    </span>
                    <span class="mt-0.5 block truncate font-mono text-xs text-base-content/50">
                      {business.slug}
                    </span>
                  </span>

                  <span class="mt-auto inline-flex items-center gap-1.5 text-sm font-medium text-primary">
                    Open
                    <.icon
                      name="hero-arrow-right"
                      class="size-4 transition-transform duration-200 group-hover:translate-x-1 motion-reduce:transition-none"
                    />
                  </span>
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

            <li :if={@can_create?}>
              <.link
                navigate={~p"/businesses/new"}
                id="picker-new-business"
                class={[
                  "group flex h-full min-h-44 flex-col items-center justify-center gap-3 rounded-2xl p-5",
                  "border-2 border-dashed border-base-300 text-base-content/60 outline-none",
                  "transition-colors duration-200 hover:border-primary/50 hover:bg-primary/5 hover:text-primary",
                  "focus-visible:border-primary/50 focus-visible:bg-primary/5 focus-visible:text-primary"
                ]}
              >
                <span class="flex size-12 items-center justify-center rounded-xl bg-base-200 transition-colors duration-200 group-hover:bg-primary/10">
                  <.icon name="hero-plus" class="size-6" />
                </span>
                <span class="text-sm font-medium">New business</span>
              </.link>
            </li>
          </ul>

          <details
            :if={@archived != []}
            id="archived-businesses"
            class="group/archived mt-8 rounded-2xl border border-base-300 bg-base-100"
          >
            <summary
              id="archived-toggle"
              class="flex cursor-pointer list-none items-center justify-between gap-3 rounded-2xl px-5 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-200/60 [&::-webkit-details-marker]:hidden"
            >
              <span class="inline-flex items-center gap-2">
                <.icon name="hero-archive-box" class="size-4" /> Archived ({length(@archived)})
              </span>
              <.icon
                name="hero-chevron-down"
                class="size-4 transition-transform duration-200 group-open/archived:rotate-180"
              />
            </summary>
            <ul class="divide-y divide-base-200 border-t border-base-200">
              <li
                :for={business <- @archived}
                id={"archived-business-#{business.id}"}
                class="flex items-center gap-3 px-5 py-3"
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
          </details>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp current?(%{business: %{id: id}}, %{id: id}), do: true
  defp current?(_scope, _business), do: false

  defp welcome(%{full_name: name}) when is_binary(name) and name != "",
    do: "Welcome back, #{name}"

  defp welcome(%{username: name}) when is_binary(name) and name != "", do: "Welcome back, #{name}"
  defp welcome(_user), do: "Welcome back"

  defp count_line(0), do: "Choose where to start."
  defp count_line(1), do: "You have 1 business. Open it to carry on."
  defp count_line(count), do: "You have #{count} businesses. Choose one to work in."

  defp card_count(entries, can_create?), do: length(entries) + if(can_create?, do: 1, else: 0)

  # Literal class strings so Tailwind emits them. By id, so a business keeps its
  # colour when the list changes around it.
  @tile_tones {
    "bg-indigo-100 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300",
    "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300",
    "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300",
    "bg-rose-100 text-rose-700 dark:bg-rose-950 dark:text-rose-300",
    "bg-sky-100 text-sky-700 dark:bg-sky-950 dark:text-sky-300",
    "bg-violet-100 text-violet-700 dark:bg-violet-950 dark:text-violet-300"
  }

  defp tile_tone(id), do: elem(@tile_tones, rem(id, tuple_size(@tile_tones)))

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end
end
