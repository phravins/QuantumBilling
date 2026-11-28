defmodule QuantumBillingWeb.AuditLogsLive do
  @moduledoc """
  The activity log: every change made in the business, who made it and when.

  Owners only (the router's `:owner` live_session): it shows every member's
  actions and IP addresses. Filters live in the URL, so a filtered view can be
  bookmarked and the back button works.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Accounts
  alias QuantumBilling.Audit
  alias QuantumBilling.Audit.Catalog
  alias QuantumBilling.Compliance
  alias QuantumBilling.Events
  alias QuantumBilling.Settings

  @per_page 50

  # Kept in `details` for the page itself, not shown as details.
  @reserved ~w(label changes actor via edits currency)

  # Older entries name their record under these keys instead of "label".
  @legacy_name_keys ~w(invoice_number note_number number ewb_number name title client_name email)

  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe(Events.audit_logs_topic())

    {:ok,
     socket
     |> assign(:page_title, "Audit log")
     |> assign(:active_nav, :settings)
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> assign(:selected_log, nil)
     |> assign(:selected_link, nil)
     |> assign(:row_ids, MapSet.new())
     |> assign(:members, members(socket.assigns.current_scope))
     |> assign(:categories, Catalog.categories())
     |> assign_time_zone()
     |> stream_configure(:logs, dom_id: &"audit-row-#{&1.id}")}
  end

  def handle_params(params, _uri, socket) do
    filters = parse_filters(params, socket.assigns.members)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filter_query(filters, true)))
     |> assign(:page, 1)
     |> load_page()}
  end

  ## Live updates

  # New entries appear on the first page only, so later pages don't shift.
  def handle_info({:audit_log_created, log}, socket) do
    if socket.assigns.page == 1 and Audit.matches?(log, query_opts(socket)) do
      total = socket.assigns.total + 1

      {:noreply,
       socket
       |> assign(:total, total)
       |> assign(:total_pages, max(ceil(total / socket.assigns.per_page), 1))
       |> update(:row_ids, &MapSet.put(&1, log.id))
       |> stream_insert(:logs, log, at: 0, limit: socket.assigns.per_page)}
    else
      {:noreply, socket}
    end
  end

  # A merged autosave: refresh the row (and the drawer) where it is shown.
  def handle_info({:audit_log_updated, log}, socket) do
    socket =
      if MapSet.member?(socket.assigns.row_ids, log.id),
        do: stream_insert(socket, :logs, log),
        else: socket

    socket =
      case socket.assigns.selected_log do
        %{id: id} when id == log.id -> assign(socket, :selected_log, log)
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Events

  def handle_event("filter", params, socket) do
    filters = parse_filters(params, socket.assigns.members)
    {:noreply, push_patch(socket, to: filter_path(filter_query(filters, false)))}
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

  def handle_event("paginate", %{"page" => page}, socket) do
    case Integer.parse(to_string(page)) do
      {page, ""} -> {:noreply, socket |> assign(:page, page) |> load_page()}
      _not_a_page -> {:noreply, socket}
    end
  end

  def handle_event("show", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %{} = log <- Audit.get_log(id) do
      {:noreply,
       socket
       |> assign(:selected_log, log)
       |> assign(:selected_link, record_link(log))}
    else
      _missing -> {:noreply, put_flash(socket, :error, "That entry is no longer in the log.")}
    end
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, selected_log: nil, selected_link: nil)}
  end

  ## Loading

  defp load_page(socket) do
    result =
      Audit.page(
        [page: socket.assigns.page, per_page: socket.assigns.per_page] ++ query_opts(socket)
      )

    socket
    |> assign(total: result.total, total_pages: result.total_pages, page: result.page)
    |> assign(:row_ids, MapSet.new(result.rows, & &1.id))
    |> stream(:logs, result.rows, reset: true)
  end

  defp query_opts(%{assigns: %{filters: filters, utc_offset: offset}}) do
    [
      q: filters.q,
      actions: if(filters.category != "", do: Catalog.actions(filters.category)),
      from: day_start(filters.from, offset),
      to: day_start(filters.to && Date.add(filters.to, 1), offset)
    ] ++ who_opts(filters.who)
  end

  defp who_opts("api"), do: [actor: :api]
  defp who_opts("system"), do: [actor: :system]
  defp who_opts(""), do: []
  defp who_opts(user_id), do: [user_id: String.to_integer(user_id)]

  # Midnight in the business's time zone, as a UTC instant.
  defp day_start(nil, _offset), do: nil

  defp day_start(%Date{} = date, offset) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-offset, :second)
  end

  defp members(%{business: %{} = business}) do
    business
    |> Accounts.list_members()
    |> Enum.map(fn membership ->
      {display_name(membership.user), to_string(membership.user.id)}
    end)
  end

  defp members(_scope), do: []

  defp assign_time_zone(socket) do
    zone =
      case Settings.get_organization() do
        %{timezone: zone} when is_binary(zone) and zone != "" -> zone
        _none -> "Asia/Kolkata"
      end

    now = DateTime.utc_now(:second)
    offset = NaiveDateTime.diff(Compliance.local_time(now, zone), DateTime.to_naive(now))

    assign(socket, utc_offset: offset, zone_label: zone_label(zone, offset))
  end

  defp zone_label(_zone, 0), do: "UTC"

  defp zone_label(zone, offset) do
    sign = if offset < 0, do: "-", else: "+"
    minutes = div(abs(offset), 60)
    "#{zone} (UTC#{sign}#{div(minutes, 60)}:#{String.pad_leading("#{rem(minutes, 60)}", 2, "0")})"
  end

  ## Filters

  defp parse_filters(params, members) do
    {from, to} = order_dates(date_param(params["from"]), date_param(params["to"]))

    %{
      q: text_param(params["q"]),
      who: who_param(params["who"], members),
      category: if(params["category"] in Catalog.categories(), do: params["category"], else: ""),
      from: from,
      to: to
    }
  end

  defp text_param(value) when is_binary(value), do: value |> String.trim() |> String.slice(0, 100)
  defp text_param(_value), do: ""

  defp who_param(value, _members) when value in ["api", "system"], do: value

  defp who_param(value, members) when is_binary(value) do
    if Enum.any?(members, fn {_name, id} -> id == value end), do: value, else: ""
  end

  defp who_param(_value, _members), do: ""

  defp date_param(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp date_param(_value), do: nil

  defp order_dates(%Date{} = from, %Date{} = to) do
    if Date.compare(from, to) == :gt, do: {to, from}, else: {from, to}
  end

  defp order_dates(from, to), do: {from, to}

  # The filters as query params; blanks dropped for the URL, kept for the form.
  defp filter_query(filters, keep_blank?) do
    %{
      "q" => filters.q,
      "who" => filters.who,
      "category" => filters.category,
      "from" => filters.from && Date.to_iso8601(filters.from),
      "to" => filters.to && Date.to_iso8601(filters.to)
    }
    |> Map.new(fn {key, value} -> {key, value || ""} end)
    |> Map.reject(fn {_key, value} -> not keep_blank? and value == "" end)
  end

  defp filter_path(query) when map_size(query) == 0, do: ~p"/settings/audit-logs"
  defp filter_path(query), do: ~p"/settings/audit-logs?#{query}"

  defp filtered?(filters), do: filter_query(filters, false) != %{}

  ## Rendering

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      sidebar={:settings}
      active_sub={:"audit-logs"}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.header>
        Audit log
        <:subtitle>
          Every change made in this business: who made it, what changed and when.
          Only owners can see this page.
        </:subtitle>
      </.header>

      <.form
        for={@filter_form}
        id="audit-filters"
        phx-change="filter"
        phx-submit="filter"
        class="mb-3 grid grid-cols-2 gap-2 sm:grid-cols-4 lg:grid-cols-[minmax(0,1.6fr)_repeat(4,minmax(0,1fr))_auto] lg:items-end [&_.fieldset]:mb-0"
      >
        <div class="relative col-span-2 sm:col-span-4 lg:col-span-1">
          <span class={[micro_label_class(), "mb-1 block"]}>Search</span>
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute bottom-2.5 left-2.5 size-3.5 text-base-content/45"
          />
          <.input
            field={@filter_form[:q]}
            id="audit-filter-q"
            type="search"
            placeholder="Invoice number, client, name…"
            autocomplete="off"
            class={filter_input_class()}
          />
        </div>

        <div>
          <label for="audit-filter-who" class={[micro_label_class(), "mb-1 block"]}>Who</label>
          <.input
            field={@filter_form[:who]}
            id="audit-filter-who"
            type="select"
            options={who_options(@members)}
            class={filter_select_class()}
          />
        </div>

        <div>
          <label for="audit-filter-category" class={[micro_label_class(), "mb-1 block"]}>
            Activity
          </label>
          <.input
            field={@filter_form[:category]}
            id="audit-filter-category"
            type="select"
            prompt="All activity"
            options={@categories}
            class={filter_select_class()}
          />
        </div>

        <div>
          <label for="audit-filter-from" class={[micro_label_class(), "mb-1 block"]}>From</label>
          <.input
            field={@filter_form[:from]}
            id="audit-filter-from"
            type="date"
            class={filter_select_class()}
          />
        </div>

        <div>
          <label for="audit-filter-to" class={[micro_label_class(), "mb-1 block"]}>To</label>
          <.input
            field={@filter_form[:to]}
            id="audit-filter-to"
            type="date"
            class={filter_select_class()}
          />
        </div>

        <div class="col-span-2 flex items-end sm:col-span-4 lg:col-span-1">
          <.link
            :if={filtered?(@filters)}
            id="audit-clear-filters"
            patch={~p"/settings/audit-logs"}
            class={[filter_button_class(), "w-full justify-center lg:w-auto"]}
          >
            <.icon name="hero-x-mark" class="size-3.5" /> Clear
          </.link>
        </div>
      </.form>

      <.card padding="px-2 pt-1 pb-2" class="flex flex-1 flex-col">
        <div
          :if={@total > 0}
          class={[
            "hidden lg:grid",
            row_grid_class(),
            "border-b border-base-300 px-2 py-2.5 text-2xs font-semibold uppercase tracking-wider text-(--qb-faint)"
          ]}
        >
          <span></span>
          <span>Activity</span>
          <span>Who</span>
          <span>When</span>
          <span>IP address</span>
          <span></span>
        </div>

        <div :if={@total == 0} id="audit-empty" class="flex flex-1 flex-col justify-center">
          <.empty_state
            icon="hero-clipboard-document-list"
            title={
              if filtered?(@filters), do: "Nothing matches these filters", else: "No activity yet"
            }
            description={
              if filtered?(@filters),
                do: "Try another member, activity or date range.",
                else:
                  "When anyone creates, edits or deletes invoices, clients, templates or settings, it shows up here."
            }
          />
        </div>

        <ul id="audit-rows" phx-update="stream" class={[@total == 0 && "hidden"]}>
          <li
            :for={{dom_id, log} <- @streams.logs}
            id={dom_id}
            class="border-b border-base-300 last:border-0"
          >
            <.log_row log={log} utc_offset={@utc_offset} />
          </li>
        </ul>

        <div :if={@total > 0} class="mt-auto flex items-center justify-between gap-3 pt-4">
          <p class="text-xs text-base-content/45">
            {@total} {if @total == 1, do: "entry", else: "entries"} · times in {@zone_label}
          </p>
          <.pagination
            current_page={@page}
            total_pages={@total_pages}
            has_next={@page < @total_pages}
            fit_rows
          />
        </div>
      </.card>

      <.log_drawer
        :if={@selected_log}
        log={@selected_log}
        link={@selected_link}
        utc_offset={@utc_offset}
        zone_label={@zone_label}
      />
    </Layouts.app>
    """
  end

  attr :log, :map, required: true
  attr :utc_offset, :integer, required: true

  defp log_row(assigns) do
    assigns =
      assign(assigns, actor: actor(assigns.log), change_count: change_count(assigns.log))

    ~H"""
    <button
      type="button"
      phx-click="show"
      phx-value-id={@log.id}
      class={[
        "grid w-full grid-cols-[2rem_minmax(0,1fr)_auto] items-center gap-x-3 px-2 py-2.5 text-left",
        "rounded-field transition-colors hover:bg-(--qb-row-hover) focus-visible:outline-none",
        "focus-visible:ring-2 focus-visible:ring-primary/25 cursor-pointer",
        row_grid_class()
      ]}
    >
      <span class={[
        "flex size-8 items-center justify-center rounded-full",
        tone_class(Catalog.tone(@log.action))
      ]}>
        <.icon name={Catalog.icon(@log.action)} class="size-4" />
      </span>

      <span class="min-w-0">
        <span class="block truncate text-sm font-medium">{Catalog.label(@log.action)}</span>
        <span class="block truncate text-xs text-base-content/55">
          {subject(@log)}<span :if={@change_count > 0} class="text-base-content/40"> · {@change_count} {if @change_count ==
                                                                                                             1,
                                                                                                           do:
                                                                                                             "change",
                                                                                                           else:
                                                                                                             "changes"}</span>
        </span>
        <span class="mt-0.5 block truncate text-xs text-base-content/45 lg:hidden">
          {@actor.name}<span :if={@log.ip_address}> · {@log.ip_address}</span>
        </span>
      </span>

      <span class="hidden min-w-0 items-center gap-2 lg:flex">
        <.actor_avatar actor={@actor} />
        <span class="min-w-0">
          <span class="block truncate text-sm">{@actor.name}</span>
          <span class="block truncate text-xs text-base-content/45">{@actor.detail}</span>
        </span>
      </span>

      <time
        datetime={DateTime.to_iso8601(@log.inserted_at)}
        title={local_time(@log.inserted_at, @utc_offset, "%d %b %Y, %H:%M:%S")}
        class="shrink-0 text-right text-xs text-base-content/55 lg:text-left"
      >
        <span class="block">{local_time(@log.inserted_at, @utc_offset, "%d %b %Y")}</span>
        <span class="block text-base-content/40">
          {local_time(@log.inserted_at, @utc_offset, "%H:%M")}
        </span>
      </time>

      <span class="hidden truncate font-mono text-xs text-base-content/50 lg:block">
        {@log.ip_address || "—"}
      </span>

      <.icon name="hero-chevron-right" class="hidden size-4 text-base-content/30 lg:block" />
    </button>
    """
  end

  attr :actor, :map, required: true

  defp actor_avatar(assigns) do
    ~H"""
    <span class={[avatar_class(), "shrink-0 bg-base-200 text-base-content/60"]}>
      <%= if @actor.icon do %>
        <.icon name={@actor.icon} class="size-3.5" />
      <% else %>
        {initials(@actor.name)}
      <% end %>
    </span>
    """
  end

  attr :log, :map, required: true
  attr :link, :string, default: nil
  attr :utc_offset, :integer, required: true
  attr :zone_label, :string, required: true

  defp log_drawer(assigns) do
    details = assigns.log.details || %{}

    assigns =
      assign(assigns,
        actor: actor(assigns.log),
        changes: sorted_changes(details),
        other_details: other_details(details),
        edits: details["edits"],
        currency: currency(details)
      )

    ~H"""
    <div
      id="audit-log-drawer"
      class="fixed inset-0 z-50 flex justify-end"
      role="dialog"
      aria-modal="true"
      aria-labelledby="audit-log-drawer-title"
      phx-window-keydown="close"
      phx-key="Escape"
    >
      <div
        class="absolute inset-0 bg-black/40"
        aria-hidden="true"
        phx-click="close"
        phx-mounted={JS.transition({"ease-out duration-200", "opacity-0", "opacity-100"})}
      >
      </div>

      <aside
        class="relative flex h-full w-full max-w-lg flex-col border-l border-base-300 bg-base-100 shadow-2xl"
        phx-mounted={JS.transition({"ease-out duration-200", "translate-x-full", "translate-x-0"})}
      >
        <header class="flex items-start gap-3 border-b border-base-300 px-5 py-4">
          <span class={[
            "flex size-9 shrink-0 items-center justify-center rounded-full",
            tone_class(Catalog.tone(@log.action))
          ]}>
            <.icon name={Catalog.icon(@log.action)} class="size-4.5" />
          </span>
          <div class="min-w-0 flex-1">
            <h2 id="audit-log-drawer-title" class="text-base font-semibold tracking-tight">
              {Catalog.label(@log.action)}
            </h2>
            <p class="text-xs text-base-content/55">
              {local_time(@log.inserted_at, @utc_offset, "%d %b %Y, %H:%M:%S")} · {@zone_label}
            </p>
          </div>
          <button
            type="button"
            id="audit-log-drawer-close"
            phx-click="close"
            aria-label="Close"
            class={row_action_class()}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>

        <div class="flex-1 space-y-6 overflow-y-auto px-5 py-5">
          <section class="grid grid-cols-[6rem_minmax(0,1fr)] gap-x-4 gap-y-3 text-sm">
            <span class="text-base-content/50">Record</span>
            <span class="min-w-0">
              <span class="block truncate font-medium">{subject(@log)}</span>
              <span class="block text-xs text-base-content/50">
                {Catalog.category(@log.action)}<span :if={@log.resource_id}> · #{@log.resource_id}</span>
              </span>
              <.link
                :if={@link}
                id="audit-record-link"
                navigate={@link}
                class="mt-1 inline-flex items-center gap-1 text-xs font-medium text-primary hover:underline"
              >
                Open <.icon name="hero-arrow-up-right" class="size-3" />
              </.link>
            </span>

            <span class="text-base-content/50">By</span>
            <span class="flex min-w-0 items-center gap-2">
              <.actor_avatar actor={@actor} />
              <span class="min-w-0">
                <span class="block truncate font-medium">{@actor.name}</span>
                <span class="block truncate text-xs text-base-content/50">{@actor.detail}</span>
              </span>
            </span>

            <span class="text-base-content/50">IP address</span>
            <span class="font-mono text-xs leading-5">{@log.ip_address || "Not recorded"}</span>

            <%= if is_integer(@edits) and @edits > 1 do %>
              <span class="text-base-content/50">Saves</span>
              <span class="text-xs leading-5">
                {@edits} saves in one sitting, shown as one entry
              </span>
            <% end %>
          </section>

          <section :if={@changes != []}>
            <h3 class={[micro_label_class(), "mb-2"]}>What changed</h3>
            <div class="overflow-hidden rounded-field border border-base-300">
              <table id="audit-changes" class="w-full table-fixed text-left text-xs">
                <thead class="bg-(--qb-head-bg) text-2xs uppercase tracking-wider text-(--qb-faint)">
                  <tr>
                    <th class="w-1/3 px-3 py-2 font-semibold">Field</th>
                    <th class="px-3 py-2 font-semibold">Before</th>
                    <th class="px-3 py-2 font-semibold">After</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={{field, change} <- @changes}
                    id={"audit-change-#{field}"}
                    class="border-t border-base-300 align-top"
                  >
                    <td class="px-3 py-2 font-medium">{Catalog.field_label(field)}</td>
                    <%= case change do %>
                      <% %{"from" => from, "to" => to} -> %>
                        <td class="break-words px-3 py-2 text-base-content/55">
                          {format_value(field, from, @currency)}
                        </td>
                        <td class="break-words px-3 py-2 font-medium">
                          {format_value(field, to, @currency)}
                        </td>
                      <% other -> %>
                        <td colspan="2" class="px-3 py-2 text-base-content/70">
                          {summary(other)}
                        </td>
                    <% end %>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section :if={@other_details != []}>
            <h3 class={[micro_label_class(), "mb-2"]}>Details</h3>
            <dl class="grid grid-cols-[minmax(0,1fr)_minmax(0,1.6fr)] gap-x-4 gap-y-2 text-sm">
              <%= for {key, value} <- @other_details do %>
                <dt class="truncate text-base-content/50">{Catalog.field_label(key)}</dt>
                <dd class="break-words">{format_value(key, value, @currency)}</dd>
              <% end %>
            </dl>
          </section>

          <details class="group rounded-field border border-base-300">
            <summary class="flex cursor-pointer list-none items-center justify-between px-3 py-2 text-xs font-medium text-base-content/60 hover:text-base-content">
              Raw data
              <.icon
                name="hero-chevron-down"
                class="size-3.5 transition-transform group-open:rotate-180"
              />
            </summary>
            <pre class="max-h-72 overflow-auto border-t border-base-300 bg-base-200/50 p-3 font-mono text-2xs leading-relaxed">{Jason.encode!(@log.details || %{}, pretty: true)}</pre>
          </details>
        </div>
      </aside>
    </div>
    """
  end

  ## Presentation helpers

  defp row_grid_class do
    "lg:grid-cols-[2rem_minmax(0,1.5fr)_minmax(0,1fr)_7rem_8rem_1rem]"
  end

  defp filter_select_class do
    "h-8 w-full rounded-field border border-base-300 bg-base-100 px-2.5 text-xs font-medium " <>
      "text-base-content focus:outline-none focus:border-(--qb-field-focus)"
  end

  defp who_options(members) do
    [{"Everyone", ""}] ++
      members ++
      [{"API keys", "api"}, {"System & automatic", "system"}]
  end

  defp tone_class(:create), do: "bg-success/10 text-success"
  defp tone_class(:update), do: "bg-info/10 text-info"
  defp tone_class(:danger), do: "bg-error/10 text-error"
  defp tone_class(_info), do: "bg-base-200 text-base-content/60"

  defp local_time(%DateTime{} = at, offset, format) do
    at |> DateTime.add(offset, :second) |> Calendar.strftime(format)
  end

  # The record's name as stored with the entry, else its kind and id.
  defp subject(%{details: details} = log) do
    details = details || %{}

    Enum.find_value(["label" | @legacy_name_keys], fn key ->
      case details[key] do
        value when is_binary(value) and value != "" -> value
        _missing -> nil
      end
    end) || fallback_subject(log)
  end

  defp fallback_subject(%{resource_type: type, resource_id: id}) do
    [type && Catalog.field_label(type), id]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp change_count(%{details: %{"changes" => changes}}) when is_map(changes),
    do: map_size(changes)

  defp change_count(_log), do: 0

  # Who acted. A deleted member or key still has the name stored with the entry.
  defp actor(log) do
    details = log.details || %{}

    cond do
      log.user ->
        %{name: display_name(log.user), detail: log.user.email, icon: nil}

      log.api_key ->
        %{name: log.api_key.name, detail: "API key", icon: "hero-key"}

      log.api_key_id ->
        %{name: details["actor"] || "Deleted API key", detail: "API key", icon: "hero-key"}

      log.user_id || is_binary(details["actor"]) ->
        %{name: details["actor"] || "Former member", detail: "No longer on the team", icon: nil}

      details["via"] == "public_link" ->
        %{name: "Client", detail: "Through a shared link", icon: "hero-link"}

      details["via"] == "razorpay" ->
        %{name: "Razorpay", detail: "Payment notification", icon: "hero-credit-card"}

      true ->
        %{name: "System", detail: "Automatic", icon: "hero-cog-6-tooth"}
    end
  end

  defp display_name(user) do
    Enum.find([user.full_name, user.username, user.email], &(is_binary(&1) and &1 != "")) ||
      "Member"
  end

  defp initials(name) do
    case String.split(name, ~r/[\s@._-]+/, trim: true) do
      [first, second | _] -> String.upcase(String.first(first) <> String.first(second))
      [single] -> single |> String.slice(0, 2) |> String.upcase()
      [] -> "?"
    end
  end

  defp record_link(log) do
    path = Catalog.record_path(log.resource_type, log.resource_id, log.details || %{})

    cond do
      is_nil(path) -> nil
      Catalog.removal?(log.action) and Catalog.own_page?(log.resource_type) -> nil
      Audit.record_open?(link_type(log), link_id(log)) -> path
      true -> nil
    end
  end

  # A credit note opens its invoice.
  defp link_type(%{resource_type: "CreditNote"}), do: "Invoice"
  defp link_type(%{resource_type: type}), do: type

  defp link_id(%{resource_type: "CreditNote", details: details}),
    do: (details || %{})["invoice_id"]

  defp link_id(%{resource_id: id}), do: id

  defp sorted_changes(%{"changes" => changes}) when is_map(changes) do
    Enum.sort_by(changes, fn {field, _change} -> Catalog.field_label(field) end)
  end

  defp sorted_changes(_details), do: []

  defp other_details(details) do
    details
    |> Map.drop(@reserved)
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp currency(%{"changes" => %{"currency" => %{"to" => code}}}) when is_binary(code), do: code
  defp currency(%{"currency" => code}) when is_binary(code), do: code
  defp currency(_details), do: "INR"

  defp summary(%{"redacted" => true}), do: "Changed (value hidden)"
  defp summary(%{"changed" => true}), do: "Changed"

  defp summary(%{"items" => counts}) when is_map(counts) do
    [{"added", "added"}, {"removed", "removed"}, {"changed", "edited"}]
    |> Enum.flat_map(fn {key, word} ->
      case counts[key] do
        count when is_integer(count) and count > 0 -> ["#{count} #{word}"]
        _none -> []
      end
    end)
    |> case do
      [] -> "Changed"
      parts -> Enum.join(parts, " · ")
    end
  end

  # A nested record (an address, say): name the fields that moved.
  defp summary(%{"changes" => inner}) when is_map(inner) and map_size(inner) > 0 do
    "Changed " <>
      (inner |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &Catalog.field_label/1))
  end

  defp summary(%{"changes" => _empty}), do: "Changed"

  defp summary(other), do: plain_value(other)

  defp format_value(field, value, currency) when is_integer(value) do
    if Catalog.money_field?(field), do: money(value, currency), else: Integer.to_string(value)
  end

  defp format_value(_field, value, _currency), do: plain_value(value)

  defp plain_value(nil), do: "—"
  defp plain_value(""), do: "—"
  defp plain_value(true), do: "Yes"
  defp plain_value(false), do: "No"
  defp plain_value(value) when is_binary(value), do: value
  defp plain_value(value) when is_number(value), do: to_string(value)
  defp plain_value(value) when is_atom(value), do: Atom.to_string(value)
  defp plain_value(value), do: Jason.encode!(value)
end
