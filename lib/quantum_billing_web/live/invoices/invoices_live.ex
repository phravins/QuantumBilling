defmodule QuantumBillingWeb.InvoicesLive do
  @moduledoc """
  The Invoices list page: search, status filter, sortable columns, and
  pagination over the full set of GST invoices.

  All data is a hardcoded in-memory dataset pending the multi-tenant Ecto
  schema. `mount/3` builds the dataset once; `handle_event/3` only ever
  updates raw filter/sort/page state, and `render/1` re-derives the visible
  rows fresh on every render so there is a single source of truth.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.InvoicesComponents

  @per_page 10

  @status_options [
    "All Status",
    "E-Invoice Generated",
    "Pending E-Invoice",
    "Draft",
    "E-Invoice Failed",
    "Cancelled"
  ]

  @seed_rows [
    %{
      seq: 15489,
      client: "V2V Technologies",
      invoice_date: ~D[2024-05-28],
      amount: 150_000,
      status: "E-Invoice Generated"
    },
    %{
      seq: 15488,
      client: "RealOffice Solutions",
      invoice_date: ~D[2024-05-28],
      amount: 75_400,
      status: "Pending E-Invoice"
    },
    %{
      seq: 15487,
      client: "DreamNest Builders",
      invoice_date: ~D[2024-05-27],
      amount: 210_000,
      status: "E-Invoice Generated"
    },
    %{
      seq: 15486,
      client: "Arch Info-Tech",
      invoice_date: ~D[2024-05-27],
      amount: 32_950,
      status: "Draft"
    },
    %{
      seq: 15485,
      client: "PressuCare Medicals",
      invoice_date: ~D[2024-05-26],
      amount: 500_000,
      status: "E-Invoice Failed"
    },
    %{
      seq: 15484,
      client: "Insta Capital",
      invoice_date: ~D[2024-05-26],
      amount: 120_000,
      status: "E-Invoice Generated"
    },
    %{
      seq: 15483,
      client: "Raam Techlink",
      invoice_date: ~D[2024-05-25],
      amount: 48_600,
      status: "Pending E-Invoice"
    },
    %{
      seq: 15482,
      client: "SoftSphere Solutions",
      invoice_date: ~D[2024-05-24],
      amount: 88_000,
      status: "E-Invoice Generated"
    },
    %{
      seq: 15481,
      client: "TechNova Systems",
      invoice_date: ~D[2024-05-24],
      amount: 115_000,
      status: "Cancelled"
    },
    %{
      seq: 15480,
      client: "Bright Future Pvt Ltd",
      invoice_date: ~D[2024-05-23],
      amount: 63_250,
      status: "E-Invoice Generated"
    }
  ]

  @client_pool Enum.map(@seed_rows, & &1.client) ++
                 [
                   "NextGen Traders",
                   "Sunrise Apparel Co",
                   "BlueOcean Logistics",
                   "Vertex Engineering Works",
                   "Golden Harvest Foods",
                   "Skyline Constructions",
                   "Metro Retail Ventures",
                   "Prime Auto Components",
                   "Silverline Textiles",
                   "Northstar Consulting"
                 ]

  @amount_pool [
    45_000,
    62_500,
    78_900,
    99_000,
    110_000,
    135_000,
    160_000,
    185_000,
    225_000,
    260_000,
    305_000,
    350_000,
    420_000,
    480_000,
    525_000
  ]

  @status_cycle [
    "E-Invoice Generated",
    "E-Invoice Generated",
    "E-Invoice Generated",
    "Pending E-Invoice",
    "E-Invoice Generated",
    "Draft",
    "E-Invoice Generated",
    "Cancelled",
    "Pending E-Invoice",
    "E-Invoice Failed"
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Invoices")
     |> assign(:active_nav, :invoices)
     |> assign(:all_invoices, all_invoices())
     |> assign(:search, "")
     |> assign(:status_filter, "All Status")
     |> assign(:sort_field, :invoice_date)
     |> assign(:sort_dir, :desc)
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
    filtered =
      assigns.all_invoices
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
        status_options: @status_options
      )

    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <.header>
        Invoices
        <:subtitle>Manage and track all your GST invoices</:subtitle>
        <:actions>
          <button type="button" class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> Create New GST Invoice
          </button>
        </:actions>
      </.header>

      <div class="card rounded-box border border-base-300 bg-base-100 p-5">
        <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <form phx-change="search" phx-submit="search" class="relative w-full sm:max-w-xs">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
            />
            <input
              type="text"
              name="q"
              value={@search}
              phx-debounce="300"
              placeholder="Search invoices..."
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
              <ul tabindex="0" class="dropdown-content menu z-10 mt-2 w-56 rounded-box bg-base-100 p-2 shadow">
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

        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>
                  <.sortable_th
                    label="Invoice #"
                    field={:seq}
                    current_field={@sort_field}
                    current_dir={@sort_dir}
                  />
                </th>
                <th>Client</th>
                <th>
                  <.sortable_th
                    label="Invoice Date"
                    field={:invoice_date}
                    current_field={@sort_field}
                    current_dir={@sort_dir}
                  />
                </th>
                <th>
                  <.sortable_th
                    label="Due Date"
                    field={:due_date}
                    current_field={@sort_field}
                    current_dir={@sort_dir}
                  />
                </th>
                <th>Total Amount</th>
                <th>Status</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} id={"invoice-#{row.seq}"}>
                <td class="font-medium text-primary">{row.number}</td>
                <td>{row.client}</td>
                <td>{format_date(row.invoice_date)}</td>
                <td>{format_date(row.due_date)}</td>
                <td>{indian_amount(row.amount)}</td>
                <td><.status_badge status={row.status} /></td>
                <td>
                  <div class="flex gap-1">
                    <button type="button" class="btn btn-ghost btn-xs" aria-label="View invoice">
                      <.icon name="hero-eye" class="size-4" />
                    </button>
                    <button type="button" class="btn btn-ghost btn-xs" aria-label="Edit invoice">
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

  defp all_invoices do
    seed = Enum.map(@seed_rows, &finalize_row/1)
    generated = Enum.map(1..88, &generated_row/1)
    seed ++ generated
  end

  defp finalize_row(row) do
    Map.merge(row, %{number: "INV-2024-#{row.seq}", due_date: Date.add(row.invoice_date, 30)})
  end

  defp generated_row(g) do
    %{
      seq: 15_479 - (g - 1),
      client: Enum.at(@client_pool, rem(g - 1, length(@client_pool))),
      invoice_date: Date.add(~D[2024-05-23], -div(g + 1, 2)),
      amount: Enum.at(@amount_pool, rem(g - 1, length(@amount_pool))) + rem(g, 7) * 500,
      status: Enum.at(@status_cycle, rem(g - 1, 10))
    }
    |> finalize_row()
  end

  defp filter_search(rows, ""), do: rows

  defp filter_search(rows, search) do
    needle = String.downcase(search)

    Enum.filter(rows, fn r ->
      String.contains?(String.downcase(r.number), needle) or
        String.contains?(String.downcase(r.client), needle)
    end)
  end

  defp filter_status(rows, "All Status"), do: rows
  defp filter_status(rows, status), do: Enum.filter(rows, &(&1.status == status))

  defp sort_rows(rows, :seq, dir), do: Enum.sort_by(rows, & &1.seq, dir)
  defp sort_rows(rows, :invoice_date, dir), do: Enum.sort_by(rows, & &1.invoice_date, {dir, Date})
  defp sort_rows(rows, :due_date, dir), do: Enum.sort_by(rows, & &1.due_date, {dir, Date})

  defp format_date(date), do: Calendar.strftime(date, "%d %b %Y")

  defp indian_amount(n) when is_integer(n) do
    s = Integer.to_string(n)
    len = String.length(s)

    {rest, last3} =
      if len > 3 do
        String.split_at(s, len - 3)
      else
        {"", s}
      end

    rest_grouped =
      rest
      |> String.reverse()
      |> String.replace(~r/(\d{2})(?=\d)/, "\\1,")
      |> String.reverse()

    "₹" <> if(rest_grouped == "", do: last3, else: rest_grouped <> "," <> last3)
  end
end
