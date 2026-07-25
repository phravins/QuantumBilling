defmodule QuantumBillingWeb.ClientsLive do
  @moduledoc """
  The Clients list page: summary tiles, search, status filter, sortable
  columns, and pagination over the full client base.

  All data is a hardcoded in-memory dataset pending the multi-tenant Ecto
  schema. `mount/3` builds the dataset once; `handle_event/3` only ever
  updates raw filter/sort/page state, and `render/1` re-derives the visible
  rows fresh on every render so there is a single source of truth.

  The four summary tiles are always computed from the *full* dataset, so they
  stay stable as an at-a-glance view of the whole client base while the table
  below them responds to search and filtering.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.ClientsComponents

  @per_page 10

  @status_options ["All Status", "Active", "Inactive", "Blocked"]

  @seed_rows [
    %{
      name: "V2V Technologies",
      gstin: "27AAACPJ8542D1ZS",
      email: "billing@v2v.in",
      phone: "+91 91234 56789",
      outstanding: 15_000,
      status: "Active"
    },
    %{
      name: "RealOffice Solutions",
      gstin: "33AACCT6790R1ZJ",
      email: "accounts@realoffice.in",
      phone: "+91 98765 43210",
      outstanding: 8_450,
      status: "Active"
    },
    %{
      name: "DreamNest Builders",
      gstin: "19ABCDE1234F1ZG",
      email: "info@dreamnest.in",
      phone: "+91 98877 66554",
      outstanding: 32_100,
      status: "Active"
    },
    %{
      name: "Arch Info-Tech",
      gstin: "07AABCE5678G1ZJ",
      email: "contact@archinfotech.in",
      phone: "+91 98776 54321",
      outstanding: 0,
      status: "Inactive"
    },
    %{
      name: "PressuCare Medicals",
      gstin: "29ABCDE9876H1ZL",
      email: "billing@pressucare.in",
      phone: "+91 77654 43210",
      outstanding: 5_000,
      status: "Active"
    },
    %{
      name: "Insta Capital",
      gstin: "27AABCI1234J1ZK",
      email: "admin@instacapital.in",
      phone: "+91 88000 11223",
      outstanding: 2_300,
      status: "Blocked"
    },
    %{
      name: "Raam Techlink",
      gstin: "33BCEPH1234K1Z5",
      email: "info@raamtech.in",
      phone: "+91 87777 23456",
      outstanding: 0,
      status: "Inactive"
    },
    %{
      name: "SoftSphere Solutions",
      gstin: "29AAQCS1111L1ZP",
      email: "hello@softsphere.com",
      phone: "+91 99887 77665",
      outstanding: 12_750,
      status: "Active"
    },
    %{
      name: "TechNova Systems",
      gstin: "07AATFN9876M1Z2",
      email: "finance@technova.in",
      phone: "+91 77688 99001",
      outstanding: 1_850,
      status: "Active"
    },
    %{
      name: "Bright Future Pvt Ltd",
      gstin: "27AABCB1234N1Z9",
      email: "accounts@brightfuture.in",
      phone: "+91 91111 22334",
      outstanding: 6_400,
      status: "Active"
    }
  ]

  @name_prefixes [
    "NextGen",
    "Sunrise",
    "BlueOcean",
    "Vertex",
    "Golden Harvest",
    "Skyline",
    "Metro",
    "Prime Auto",
    "Silverline",
    "Northstar",
    "Everest",
    "Crescent",
    "Pinnacle",
    "Radiant",
    "Orchid",
    "Quantum",
    "Zenith",
    "Maple",
    "Horizon",
    "Emerald"
  ]

  @name_suffixes [
    "Traders",
    "Industries",
    "Enterprises",
    "Logistics",
    "Textiles",
    "Exports",
    "Technologies",
    "Distributors",
    "Agencies",
    "Ventures"
  ]

  @amount_pool [
    3_200,
    7_800,
    11_400,
    18_900,
    24_500,
    29_750,
    36_200,
    41_600,
    48_300,
    55_100,
    62_400,
    71_950
  ]

  @state_codes ~w(27 33 19 07 29 24 06 36)
  @pan_letters ~w(A B C D E F G H J K L M N P Q R S T V W)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Clients")
     |> assign(:active_nav, :clients)
     |> assign(:all_clients, all_clients())
     |> assign(:search, "")
     |> assign(:status_filter, "All Status")
     |> assign(:sort_field, nil)
     |> assign(:sort_dir, :asc)
     |> assign(:page, 1)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> assign(:page, 1)}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status_filter, status) |> assign(:page, 1)}
  end

  def handle_event("sort", %{"field" => field_str}, socket) do
    field = String.to_existing_atom(field_str)

    {sort_field, sort_dir} =
      if socket.assigns.sort_field == field do
        {field, if(socket.assigns.sort_dir == :asc, do: :desc, else: :asc)}
      else
        {field, :asc}
      end

    {:noreply, assign(socket, sort_field: sort_field, sort_dir: sort_dir, page: 1)}
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    {:noreply, assign(socket, :page, String.to_integer(page_str))}
  end

  def render(assigns) do
    all = assigns.all_clients

    filtered =
      all
      |> filter_search(assigns.search)
      |> filter_status(assigns.status_filter)
      |> sort_rows(assigns.sort_field, assigns.sort_dir)

    total = length(filtered)
    total_pages = max(ceil(total / @per_page), 1)
    page = assigns.page |> max(1) |> min(total_pages)
    rows = Enum.slice(filtered, (page - 1) * @per_page, @per_page)
    range_start = if total == 0, do: 0, else: (page - 1) * @per_page + 1
    range_end = min(page * @per_page, total)

    assigns =
      assign(assigns,
        rows: rows,
        total: total,
        total_pages: total_pages,
        page: page,
        range_start: range_start,
        range_end: range_end,
        status_options: @status_options,
        metrics: metrics(all)
      )

    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <.header>
        Clients
        <:subtitle>Manage your clients and their details</:subtitle>
        <:actions>
          <button type="button" class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> Add New Client
          </button>
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
            class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
          />
          <input
            type="text"
            name="q"
            value={@search}
            phx-debounce="300"
            placeholder="Search clients..."
            class="input input-bordered w-full pl-9"
          />
        </form>

        <div class="flex items-center gap-2">
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-outline gap-2">
              <.icon name="hero-funnel" class="size-4" />
              {@status_filter}
              <.icon name="hero-chevron-down" class="size-4" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu z-10 mt-2 w-56 rounded-box bg-base-100 p-2 shadow"
            >
              <li :for={s <- @status_options}>
                <a phx-click="filter_status" phx-value-status={s}>{s}</a>
              </li>
            </ul>
          </div>

          <button type="button" class="btn btn-outline gap-2">
            <.icon name="hero-arrow-down-tray" class="size-4" /> Export
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.metric_card
          :for={m <- @metrics}
          label={m.label}
          value={m.value}
          caption={m.caption}
          icon={m.icon}
          icon_class={m.icon_class}
          phx-click="filter_status"
          phx-value-status={m.status}
        />
      </div>

      <div class="mt-4 card rounded-box border border-base-300 bg-base-100 p-5">
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>
                  <.sortable_th
                    label="Client Name"
                    field={:name}
                    current_field={@sort_field}
                    current_dir={@sort_dir}
                  />
                </th>
                <th>GSTIN</th>
                <th>Email</th>
                <th>Phone</th>
                <th>
                  <.sortable_th
                    label="Outstanding"
                    field={:outstanding}
                    current_field={@sort_field}
                    current_dir={@sort_dir}
                  />
                </th>
                <th>Status</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} id={"client-#{row.id}"}>
                <td>
                  <div class="flex items-center gap-3">
                    <.client_avatar name={row.name} />
                    <span class="font-medium">{row.name}</span>
                  </div>
                </td>
                <td>{row.gstin}</td>
                <td>{row.email}</td>
                <td>{row.phone}</td>
                <td>{rupees(row.outstanding, decimals: 2, space: true)}</td>
                <td><.status_badge status={row.status} /></td>
                <td>
                  <div class="flex gap-1">
                    <button type="button" class="btn btn-ghost btn-xs" aria-label="View client">
                      <.icon name="hero-eye" class="size-4" />
                    </button>
                    <button type="button" class="btn btn-ghost btn-xs" aria-label="Edit client">
                      <.icon name="hero-pencil-square" class="size-4" />
                    </button>
                    <button type="button" class="btn btn-ghost btn-xs" aria-label="More actions">
                      <.icon name="hero-ellipsis-vertical" class="size-4" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="mt-4 flex flex-col items-center justify-between gap-3 sm:flex-row">
          <span class="text-sm text-base-content/60">
            Showing {@range_start} to {@range_end} of {@total} entries
          </span>
          <.pagination current_page={@page} total_pages={@total_pages} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Always derived from the full client base, never the filtered subset.
  defp metrics(all) do
    total = length(all)
    counts = Enum.frequencies_by(all, & &1.status)
    active = Map.get(counts, "Active", 0)
    inactive = Map.get(counts, "Inactive", 0)
    blocked = Map.get(counts, "Blocked", 0)

    [
      %{
        label: "Total Clients",
        value: Integer.to_string(total),
        caption: "All time",
        icon: "hero-users",
        icon_class: "bg-primary/10 text-primary",
        status: "All Status"
      },
      %{
        label: "Active Clients",
        value: Integer.to_string(active),
        caption: share(active, total),
        icon: "hero-check-circle",
        icon_class: "bg-success/10 text-success",
        status: "Active"
      },
      %{
        label: "Inactive Clients",
        value: Integer.to_string(inactive),
        caption: share(inactive, total),
        icon: "hero-clock",
        icon_class: "bg-warning/10 text-warning",
        status: "Inactive"
      },
      %{
        label: "Blocked Clients",
        value: Integer.to_string(blocked),
        caption: share(blocked, total),
        icon: "hero-x-circle",
        icon_class: "bg-error/10 text-error",
        status: "Blocked"
      }
    ]
  end

  defp share(_count, 0), do: "0% of total"

  defp share(count, total) do
    pct = count / total * 100
    :erlang.float_to_binary(pct, decimals: 1) <> "% of total"
  end

  defp all_clients do
    seed = @seed_rows |> Enum.with_index(1) |> Enum.map(fn {row, i} -> Map.put(row, :id, i) end)
    seed ++ Enum.map(1..118, &generated_client/1)
  end

  defp generated_client(g) do
    status = generated_status(g)
    name = generated_name(g)

    %{
      id: g + 10,
      name: name,
      gstin: generated_gstin(g),
      email: "contact@" <> slug(name) <> ".in",
      phone: generated_phone(g),
      outstanding: generated_outstanding(g, status),
      status: status
    }
  end

  # 13 and 29 are coprime and their multiples stay under 118, so this yields
  # exactly 9 inactive and 4 blocked clients with no overlap — which, with the
  # seed rows, totals 112 active / 11 inactive / 5 blocked.
  defp generated_status(g) do
    cond do
      rem(g, 13) == 0 -> "Inactive"
      rem(g, 29) == 0 -> "Blocked"
      true -> "Active"
    end
  end

  defp generated_name(g) do
    prefix = Enum.at(@name_prefixes, rem(g - 1, length(@name_prefixes)))
    suffix = Enum.at(@name_suffixes, div(g - 1, length(@name_prefixes)))
    prefix <> " " <> suffix
  end

  defp generated_gstin(g) do
    state = Enum.at(@state_codes, rem(g, length(@state_codes)))
    letters = for offset <- 0..4, do: Enum.at(@pan_letters, rem(g + offset, length(@pan_letters)))
    digits = 1000 + rem(g * 37, 9000)
    check = Enum.at(@pan_letters, rem(g * 7, length(@pan_letters)))

    state <> Enum.join(letters) <> Integer.to_string(digits) <> check <> "1Z" <> check
  end

  defp generated_phone(g) do
    base = 7_000_000_000 + g * 1_234_567
    digits = base |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0")
    {head, tail} = String.split_at(digits, 4)
    "+91 9" <> head <> " " <> tail
  end

  defp generated_outstanding(_g, "Inactive"), do: 0

  defp generated_outstanding(g, _status) do
    Enum.at(@amount_pool, rem(g - 1, length(@amount_pool))) + rem(g, 9) * 250
  end

  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp filter_search(rows, ""), do: rows

  defp filter_search(rows, search) do
    needle = String.downcase(search)

    Enum.filter(rows, fn r ->
      String.contains?(String.downcase(r.name), needle) or
        String.contains?(String.downcase(r.gstin), needle) or
        String.contains?(String.downcase(r.email), needle)
    end)
  end

  defp filter_status(rows, "All Status"), do: rows
  defp filter_status(rows, status), do: Enum.filter(rows, &(&1.status == status))

  # No explicit sort yet: keep the natural insertion order.
  defp sort_rows(rows, nil, _dir), do: rows
  defp sort_rows(rows, :name, dir), do: Enum.sort_by(rows, & &1.name, dir)
  defp sort_rows(rows, :outstanding, dir), do: Enum.sort_by(rows, & &1.outstanding, dir)
end
