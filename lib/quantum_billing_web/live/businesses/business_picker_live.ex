defmodule QuantumBillingWeb.BusinessPickerLive do
  @moduledoc """
  Choose which business to work in (a focus screen, no sidebar).

  Continue posts to `BusinessController.switch/2`, then `BusinessReadyLive`.
  Rows show the business logo inlined (`/uploads` serves only the current
  business's), or its initials. Owners can rename, archive and restore here.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Businesses
  alias QuantumBilling.Businesses.Business
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Uploads

  # A logo bigger than this is not worth carrying in the page for a row; the
  # row shows initials instead.
  @logo_limit 600_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    entries = Businesses.list_for_user(user)

    {:ok,
     socket
     |> assign(:page_title, "Choose a business")
     |> assign(:entries, entries)
     |> assign(:logos, logos(entries))
     |> assign(:selected_id, initial_selection(socket.assigns.current_scope, entries))
     |> assign(:archived, Businesses.list_archived_owned(user))
     |> assign(:can_create?, Businesses.owns_any?(user))
     |> assign(:renaming_id, nil)
     |> assign(:rename_form, nil)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.entries, fn {b, _m} -> to_string(b.id) == to_string(id) end) do
      {business, _membership} -> {:noreply, assign(socket, :selected_id, business.id)}
      nil -> {:noreply, socket}
    end
  end

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

  # The business already open, else the first in the list.
  defp initial_selection(scope, entries) do
    current = scope.business && scope.business.id

    cond do
      current && Enum.any?(entries, fn {b, _m} -> b.id == current end) -> current
      entries != [] -> entries |> hd() |> elem(0) |> Map.fetch!(:id)
      true -> nil
    end
  end

  defp logos(entries) do
    Map.new(entries, fn {business, _membership} -> {business.id, logo_data(business)} end)
  end

  # Read from the business's own settings, and only ever a file in the uploads
  # directory, by name: a path in the settings is never followed anywhere else.
  defp logo_data(business) do
    path = Repo.with_business(business, fn -> Settings.get_organization().doc_logo_path end)

    with "/uploads/" <> name <- path,
         {:ok, file, content_type} <- Uploads.locate(name),
         {:ok, %File.Stat{size: size}} when size <= @logo_limit <- File.stat(file),
         {:ok, contents} <- File.read(file) do
      "data:#{content_type};base64,#{Base.encode64(contents)}"
    else
      _none_or_unreadable -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.focus flash={@flash} current_scope={@current_scope}>
      <div id="business-picker" class="flex w-full max-w-md flex-col">
        <header class="qb-rise mb-6 text-center">
          <h1 class="text-xl font-semibold tracking-tight">Choose a business</h1>
          <p id="picker-count" class="mt-1 text-sm text-base-content/60">
            {count_line(length(@entries))}
          </p>
        </header>

        <div
          :if={@entries == [] and not @can_create?}
          id="no-businesses"
          class="flex flex-col items-center rounded-box border border-base-300 bg-base-100 px-6 py-8 text-center"
        >
          <span class="flex size-10 items-center justify-center rounded-full bg-base-200 text-base-content/60">
            <.icon name="hero-building-office-2" class="size-5" />
          </span>
          <p class="mt-3 text-sm font-semibold">You are not part of any business yet</p>
          <p class="mt-1 text-sm text-base-content/60">
            Ask an owner to add you. It shows up here as soon as they do.
          </p>
        </div>

        <ul
          :if={@entries != [] or @can_create?}
          id="business-list"
          role="radiogroup"
          aria-label="Your businesses"
          class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300 bg-base-100"
        >
          <li :for={{business, membership} <- @entries} id={"business-#{business.id}"}>
            <%= if @renaming_id == business.id do %>
              <.form
                for={@rename_form}
                id={"rename-business-#{business.id}"}
                phx-change="validate_rename"
                phx-submit="save_rename"
                class="flex flex-col gap-1 bg-base-200/40 p-4"
              >
                <.input
                  field={@rename_form[:name]}
                  type="text"
                  label="Rename business"
                  phx-mounted={JS.focus()}
                />
                <p class="-mt-1 text-xs text-base-content/55">
                  Payment links keep working: they use <span class="font-mono">{business.slug}</span>, which does not change.
                </p>
                <div class="flex justify-end gap-2 pt-2">
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
              <div class={[
                "group flex items-center transition-colors",
                if(@selected_id == business.id, do: "bg-base-200/70", else: "hover:bg-base-200/40")
              ]}>
                <button
                  type="button"
                  role="radio"
                  aria-checked={to_string(@selected_id == business.id)}
                  id={"choose-business-#{business.id}"}
                  phx-click="select"
                  phx-value-id={business.id}
                  class="flex min-w-0 flex-1 items-center gap-3 px-4 py-3 text-left outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-base-content"
                >
                  <span class="flex size-9 shrink-0 items-center justify-center overflow-hidden rounded-field border border-base-300 bg-base-100">
                    <%= if logo = @logos[business.id] do %>
                      <img
                        src={logo}
                        alt=""
                        id={"business-logo-#{business.id}"}
                        class="max-h-full max-w-full object-contain p-1"
                      />
                    <% else %>
                      <span class="text-xs font-semibold text-base-content/70">
                        {initials(business.name)}
                      </span>
                    <% end %>
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-sm font-medium">{business.name}</span>
                    <span class="flex items-center gap-1.5 text-xs text-base-content/55">
                      <span>{if membership.role == "owner", do: "Owner", else: "Staff"}</span>
                      <span :if={current?(@current_scope, business)} aria-hidden="true">·</span>
                      <span :if={current?(@current_scope, business)} class="text-base-content">
                        Open now
                      </span>
                    </span>
                  </span>
                  <span class={[
                    "flex size-5 shrink-0 items-center justify-center rounded-full transition-colors",
                    if(@selected_id == business.id,
                      do: "bg-base-content text-base-100",
                      else: "border border-base-content/20 text-transparent"
                    )
                  ]}>
                    <.icon name="hero-check-mini" class="size-3.5" />
                  </span>
                </button>

                <div :if={membership.role == "owner"} class="flex shrink-0 items-center pr-2">
                  <button
                    type="button"
                    id={"rename-#{business.id}"}
                    phx-click="rename"
                    phx-value-id={business.id}
                    title="Rename"
                    aria-label={"Rename #{business.name}"}
                    class="rounded-field p-1.5 text-base-content/45 transition-colors hover:bg-base-content/5 hover:text-base-content"
                  >
                    <.icon name="hero-pencil-square" class="size-4" />
                  </button>
                  <button
                    :if={business.id != 1}
                    type="button"
                    id={"archive-#{business.id}"}
                    phx-click="archive"
                    phx-value-id={business.id}
                    title="Archive"
                    aria-label={"Archive #{business.name}"}
                    data-confirm={"Archive #{business.name}? It leaves this list and stops its scheduled jobs. Its records are kept, and you can restore it."}
                    class="rounded-field p-1.5 text-base-content/45 transition-colors hover:bg-error/10 hover:text-error"
                  >
                    <.icon name="hero-archive-box" class="size-4" />
                  </button>
                </div>
              </div>
            <% end %>
          </li>

          <li :if={@can_create?}>
            <.link
              navigate={~p"/businesses/new"}
              id="picker-new-business"
              class="flex items-center gap-3 px-4 py-3 text-sm text-base-content/70 transition-colors hover:bg-base-200/40 hover:text-base-content focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-base-content"
            >
              <span class="flex size-9 shrink-0 items-center justify-center rounded-field border border-dashed border-base-content/25">
                <.icon name="hero-plus" class="size-4" />
              </span>
              Create a business
            </.link>
          </li>
        </ul>

        <details
          :if={@archived != []}
          id="archived-businesses"
          class="group/archived mt-4 overflow-hidden rounded-box border border-base-300 bg-base-100"
        >
          <summary
            id="archived-toggle"
            class="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-2.5 text-sm text-base-content/60 transition-colors hover:text-base-content [&::-webkit-details-marker]:hidden"
          >
            <span class="inline-flex items-center gap-2">
              <.icon name="hero-archive-box" class="size-4" /> Archived ({length(@archived)})
            </span>
            <.icon
              name="hero-chevron-down"
              class="size-4 transition-transform duration-200 group-open/archived:rotate-180"
            />
          </summary>
          <ul class="divide-y divide-base-300 border-t border-base-300">
            <li
              :for={business <- @archived}
              id={"archived-business-#{business.id}"}
              class="flex items-center gap-3 px-4 py-2.5"
            >
              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm text-base-content/70">{business.name}</span>
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

        <.link
          href={~p"/users/log-out"}
          method="delete"
          id="picker-sign-out"
          class="mx-auto mt-6 inline-flex items-center gap-1.5 text-sm text-base-content/55 transition-colors hover:text-base-content"
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Sign out
        </.link>
      </div>

      <:footer :if={@entries != []}>
        <%= if @current_scope.business do %>
          <.link navigate={~p"/dashboard"} id="picker-back" class={Layouts.focus_back_class()}>
            <.icon name="hero-arrow-left-mini" class="size-4" /> Back
          </.link>
        <% else %>
          <span />
        <% end %>

        <.link
          :if={@selected_id}
          href={~p"/businesses/#{@selected_id}/switch"}
          method="post"
          id="picker-continue"
          class={Layouts.focus_next_class()}
        >
          Continue <.icon name="hero-arrow-right-mini" class="size-4" />
        </.link>
      </:footer>
    </Layouts.focus>
    """
  end

  defp current?(%{business: %{id: id}}, %{id: id}), do: true
  defp current?(_scope, _business), do: false

  defp count_line(0), do: "Create your first business to get started."
  defp count_line(1), do: "Pick it and continue."
  defp count_line(_count), do: "Pick the one to work in."

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end
end
