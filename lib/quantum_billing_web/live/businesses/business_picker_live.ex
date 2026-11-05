defmodule QuantumBillingWeb.BusinessPickerLive do
  @moduledoc """
  Choose which business to work in (a focus screen, no sidebar).

  Continue posts to `BusinessController.switch/2`, then `BusinessReadyLive`.
  Cards show the business logo inlined (`/uploads` serves only the current
  business's), or an illustration. Owners can rename, archive and restore here.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.Illustrations, only: [company: 1]

  alias QuantumBilling.Businesses
  alias QuantumBilling.Businesses.Business
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Uploads

  # A logo bigger than this is not worth carrying in the page for a card; the
  # card shows its illustration instead.
  @logo_limit 600_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    entries = Businesses.list_for_user(user)

    {:ok,
     socket
     |> assign(:page_title, "Select your company")
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
    <Layouts.focus flash={@flash} current_scope={@current_scope} step={1} steps={2}>
      <div id="business-picker" class="flex w-full max-w-5xl flex-col">
        <header class="qb-rise mb-8 text-center sm:mb-10">
          <p id="picker-welcome" class="text-sm font-medium text-base-content/55">
            {welcome(@current_scope.user)}
          </p>
          <h1 class="mt-1.5 text-2xl font-semibold tracking-tight sm:text-3xl">
            Select your company
          </h1>
          <p id="picker-count" class="mt-2 text-sm text-base-content/60">
            {count_line(length(@entries))}
          </p>
        </header>

        <div
          :if={@entries == [] and not @can_create?}
          id="no-businesses"
          class="mx-auto flex max-w-md flex-col items-center rounded-xl border border-dashed border-base-300 bg-base-100 p-8 text-center"
        >
          <.company variant={4} class="h-32 w-auto" />
          <p class="mt-4 text-base font-semibold">You are not part of any business yet</p>
          <p class="mt-1 text-sm text-base-content/60">
            Ask an owner to add you to their business. You will see it here as soon as they do.
          </p>
        </div>

        <ul
          :if={@entries != [] or @can_create?}
          id="business-list"
          role="radiogroup"
          aria-label="Your companies"
          class={[
            "grid grid-cols-1 gap-5 sm:grid-cols-2",
            card_count(@entries, @can_create?) >= 3 && "lg:grid-cols-3",
            card_count(@entries, @can_create?) == 1 && "mx-auto w-full max-w-xs sm:grid-cols-1"
          ]}
        >
          <li
            :for={{{business, membership}, index} <- Enum.with_index(@entries)}
            id={"business-#{business.id}"}
            class="qb-rise flex flex-col"
            style={"animation-delay: #{min(index, 8) * 40}ms"}
          >
            <%= if @renaming_id == business.id do %>
              <.form
                for={@rename_form}
                id={"rename-business-#{business.id}"}
                phx-change="validate_rename"
                phx-submit="save_rename"
                class="flex min-h-72 flex-1 flex-col rounded-xl border border-base-300 bg-base-100 p-5"
              >
                <p class="mb-3 text-sm font-semibold">Rename company</p>
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
              <button
                type="button"
                role="radio"
                aria-checked={to_string(@selected_id == business.id)}
                id={"choose-business-#{business.id}"}
                phx-click="select"
                phx-value-id={business.id}
                class={[
                  "group relative flex flex-1 flex-col overflow-hidden rounded-xl border bg-base-100 text-left",
                  "shadow-sm outline-none transition-all duration-200 motion-reduce:transition-none",
                  "hover:shadow-md",
                  "focus-visible:ring-2 focus-visible:ring-base-content focus-visible:ring-offset-2 focus-visible:ring-offset-base-100",
                  if(@selected_id == business.id,
                    do: "border-base-content ring-1 ring-base-content",
                    else: "border-base-300 hover:border-base-content/30"
                  )
                ]}
              >
                <span class={[
                  "absolute right-3.5 top-3.5 z-10 flex size-7 items-center justify-center rounded-full transition-all duration-200",
                  if(@selected_id == business.id,
                    do: "scale-100 bg-base-content text-base-100",
                    else: "scale-90 border-2 border-base-content/15 bg-base-100 text-base-content/25"
                  )
                ]}>
                  <.icon name="hero-check-mini" class="size-4.5" />
                </span>

                <span class={[
                  "flex h-44 items-center justify-center",
                  scene_tone(business.id)
                ]}>
                  <%= if logo = @logos[business.id] do %>
                    <span class="flex size-28 items-center justify-center rounded-2xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/5">
                      <img
                        src={logo}
                        alt={"#{business.name} logo"}
                        id={"business-logo-#{business.id}"}
                        class="max-h-full max-w-full object-contain"
                      />
                    </span>
                  <% else %>
                    <.company
                      variant={business.id}
                      tone={building_tone(business.id)}
                      class="h-36 w-auto transition-transform duration-300 group-hover:scale-[1.04] motion-reduce:transition-none"
                    />
                  <% end %>
                </span>

                <span class="flex items-center justify-between gap-3 border-t border-base-content/5 px-5 py-4">
                  <span class="min-w-0">
                    <span class="block truncate text-base font-semibold tracking-tight">
                      {business.name}
                    </span>
                    <span class="mt-0.5 flex items-center gap-1.5 text-xs text-base-content/55">
                      <span>{if membership.role == "owner", do: "Owner", else: "Staff"}</span>
                      <span :if={current?(@current_scope, business)} aria-hidden="true">·</span>
                      <span
                        :if={current?(@current_scope, business)}
                        class="font-medium text-base-content"
                      >
                        Open now
                      </span>
                    </span>
                  </span>
                </span>
              </button>

              <div
                :if={membership.role == "owner"}
                class="mt-1.5 flex items-center justify-center gap-1"
              >
                <button
                  type="button"
                  id={"rename-#{business.id}"}
                  phx-click="rename"
                  phx-value-id={business.id}
                  class="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs text-base-content/55 transition-colors hover:bg-base-content/5 hover:text-base-content"
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
                  class="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs text-base-content/55 transition-colors hover:bg-error/10 hover:text-error"
                >
                  <.icon name="hero-archive-box" class="size-3.5" /> Archive
                </button>
              </div>
            <% end %>
          </li>

          <li :if={@can_create?} class="qb-rise flex flex-col">
            <.link
              navigate={~p"/businesses/new"}
              id="picker-new-business"
              class={[
                "group flex min-h-[15.5rem] flex-1 flex-col items-center justify-center gap-3 rounded-xl p-5",
                "border border-dashed border-base-300 bg-base-100 text-base-content/60 outline-none",
                "transition-colors duration-200 hover:border-base-content/40 hover:bg-base-200/60 hover:text-base-content",
                "focus-visible:border-base-content/40 focus-visible:bg-base-200/60"
              ]}
            >
              <span class="flex size-14 items-center justify-center rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/5 transition-transform duration-200 group-hover:scale-105">
                <.icon name="hero-plus" class="size-6" />
              </span>
              <span class="text-sm font-semibold">New company</span>
              <span class="text-xs text-base-content/50">A separate set of books</span>
            </.link>
          </li>
        </ul>

        <details
          :if={@archived != []}
          id="archived-businesses"
          class="group/archived mx-auto mt-10 w-full max-w-2xl rounded-2xl border border-base-content/10 bg-base-100/70"
        >
          <summary
            id="archived-toggle"
            class="flex cursor-pointer list-none items-center justify-between gap-3 rounded-2xl px-5 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-100 [&::-webkit-details-marker]:hidden"
          >
            <span class="inline-flex items-center gap-2">
              <.icon name="hero-archive-box" class="size-4" /> Archived ({length(@archived)})
            </span>
            <.icon
              name="hero-chevron-down"
              class="size-4 transition-transform duration-200 group-open/archived:rotate-180"
            />
          </summary>
          <ul class="divide-y divide-base-content/5 border-t border-base-content/5">
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

  defp welcome(%{full_name: name}) when is_binary(name) and name != "",
    do: "Welcome back, #{name}"

  defp welcome(%{username: name}) when is_binary(name) and name != "", do: "Welcome back, #{name}"
  defp welcome(_user), do: "Welcome back"

  defp count_line(0), do: "Create your first company to get started."
  defp count_line(1), do: "You have 1 company. Continue to open it."
  defp count_line(count), do: "You have #{count} companies. Pick one to work in."

  defp card_count(entries, can_create?), do: length(entries) + if(can_create?, do: 1, else: 0)

  # Literal classes so Tailwind emits them; picked by id so a card keeps its shade.
  @scene_tones {
    "bg-base-200/60",
    "bg-base-200/40",
    "bg-base-200/80"
  }

  # The grey shape behind each card's drawing.
  @building_tones {
    "fill-base-content/10",
    "fill-base-content/15",
    "fill-base-content/[0.07]",
    "fill-base-300"
  }

  defp scene_tone(id), do: elem(@scene_tones, rem(id, tuple_size(@scene_tones)))
  defp building_tone(id), do: elem(@building_tones, rem(id, tuple_size(@building_tones)))
end
