defmodule QuantumBillingWeb.HsnFinderLive do
  @moduledoc """
  The HSN / SAC Code & GST Rate Finder: search a curated set of common codes by
  keyword or by code, and see the applicable GST rate.

  All data comes from `QuantumBilling.HsnFinder`, which is explicit about being
  a curated reference of commonly searched codes rather than the full
  government master list — a miss here should read as "not in this smaller
  set," not as "this tool is broken," which is what the empty state says, and
  why it names the official portals that do carry the full list.

  `mount/3` seeds a default search so the page never opens blank; `render/1`
  re-runs the active tab's search from raw `query`/`tab` state on every pass,
  the same single-source-of-truth shape every other page in this app uses.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.HsnFinder

  @tabs [{:keyword, "Search by Keyword"}, {:code, "Search by HSN / SAC Code"}]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "HSN Finder")
     |> assign(:active_nav, :hsn_finder)
     |> assign(:tab, :keyword)
     |> assign(:query, "")
     |> assign(:selected_code, nil)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab = if tab == "code", do: :code, else: :keyword

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:query, "")
     |> assign(:selected_code, nil)}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> assign(:selected_code, nil)}
  end

  def handle_event("select", %{"code" => code}, socket) do
    {:noreply, assign(socket, :selected_code, code)}
  end

  def render(assigns) do
    results = search(assigns.tab, assigns.query)

    selected =
      cond do
        assigns.selected_code -> HsnFinder.get_by_code(assigns.selected_code)
        length(results) == 1 -> hd(results)
        true -> nil
      end

    assigns = assign(assigns, tabs: @tabs, results: results, selected: selected)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.header>
        <span class="inline-flex items-center gap-2">
          HSN / SAC Code &amp; GST Rate Finder
          <.help_popover id="hsn-help" label="About HSN / SAC codes">
            <span class="block">
              <span class="flex items-center gap-2.5">
                <.icon name="hero-information-circle" class="size-4 text-base-content/45" />
                <span class="font-semibold tracking-tight">About HSN / SAC</span>
              </span>

              <span class="mt-3 block text-base-content/60">
                HSN (Harmonized System of Nomenclature) is an internationally standardized
                system of names and numbers to classify traded products.
              </span>

              <span class="mt-2 block text-base-content/60">
                SAC (Services Accounting Code) is used to classify services.
              </span>
            </span>

            <span class="block">
              <span class="flex items-center gap-2.5">
                <.icon name="hero-information-circle" class="size-4 text-base-content/45" />
                <span class="font-semibold tracking-tight">Note</span>
              </span>

              <ul class="mt-3 space-y-2 text-base-content/60">
                <li>
                  GST was restructured on {format_date(HsnFinder.gst_2_0_date())} ("GST 2.0") —
                  rates below reflect the current structure, not the pre-reform slabs.
                </li>

                <li>This covers a curated set of commonly searched codes, not the full list.</li>

                <li>Please verify the HSN / SAC code and rate before use.</li>

                <li>For anything not covered here, refer to the official CBIC / GST portal.</li>
              </ul>
            </span>
          </.help_popover>
        </span>

        <:subtitle>Search and find the correct HSN / SAC code and applicable GST rate.</:subtitle>
      </.header>

      <div class="flex flex-1 flex-col gap-4">
        <.card padding="p-5">
          <div class="-mb-px flex items-center gap-6 border-b border-base-300">
            <button
              :for={{key, label} <- @tabs}
              type="button"
              phx-click="switch_tab"
              phx-value-tab={key}
              class={[
                "border-b-2 pb-2.5 text-sm transition-colors",
                if(@tab == key,
                  do: "border-base-content font-medium text-base-content",
                  else: "border-transparent text-base-content/60 hover:text-base-content"
                )
              ]}
            >
              {label}
            </button>
          </div>

          <form
            id="hsn-search"
            phx-change="search"
            phx-submit="search"
            class="mt-4 flex items-center gap-2"
          >
            <div class="relative flex-1">
              <.icon
                name="hero-magnifying-glass"
                class="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-base-content/45"
              />
              <input
                type="text"
                name="q"
                value={@query}
                phx-debounce="300"
                placeholder={
                  if @tab == :keyword,
                    do: "Enter product or service name, e.g., Laptop, Legal services",
                    else: "Enter HSN or SAC code, e.g., 8471"
                }
                class={filter_input_class()}
              />
            </div>

            <button type="submit" class={action_button_class()}>
              <.icon name="hero-magnifying-glass" class="size-4" /> Search
            </button>
          </form>

          <p :if={@tab == :keyword} class="mt-2 text-xs text-base-content/45">
            Example: Mobile phone, Consulting service, Cotton fabric, Restaurant service
          </p>
        </.card>

        <.card padding="p-5" class="flex flex-1 flex-col">
          <div class="mb-4 flex items-center justify-between">
            <h2 class="text-sm font-semibold tracking-tight">Search Results</h2>

            <span :if={@query != ""} class="text-sm font-medium text-base-content/60">
              {length(@results)} Result{if length(@results) != 1, do: "s"} Found
            </span>
          </div>

          <.empty_state
            :if={@query != "" and @results == []}
            class="flex-1 justify-center"
            icon="hero-magnifying-glass"
            title="No match in this reference set"
            description="This finder covers a curated set of commonly searched codes, not the full government master list. The CBIC and GST portals carry the complete list."
          />
          <p
            :if={@query == ""}
            class="flex flex-1 items-center justify-center py-8 text-center text-sm text-base-content/45"
          >
            Enter a search above to look up an HSN / SAC code and its GST rate.
          </p>

          <ul :if={@results != []} class="space-y-2">
            <li :for={entry <- @results}>
              <button
                type="button"
                phx-click="select"
                phx-value-code={entry.code}
                class={[
                  "flex w-full items-start justify-between gap-4 rounded-field border p-4 text-left transition-colors",
                  if(@selected && @selected.code == entry.code,
                    do: "border-base-content/30 bg-base-200/60",
                    else: "border-base-300 hover:bg-base-200/60"
                  )
                ]}
              >
                <div class="flex items-start gap-3">
                  <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-base-200 text-base-content/60">
                    <.icon name="hero-check" class="size-4" />
                  </span>

                  <div>
                    <p class="font-semibold tracking-tight">{entry.code}</p>

                    <p class="mt-0.5 text-sm text-base-content/60">{entry.description}</p>
                  </div>
                </div>

                <div class="shrink-0 rounded-field bg-base-200 px-3 py-1.5 text-center">
                  <p class="text-sm font-semibold">{entry.rate}%</p>

                  <p class="text-2xs text-base-content/45">GST Rate</p>
                </div>
              </button>
            </li>
          </ul>

          <div :if={@selected} class="mt-4 border-t border-base-300 pt-4">
            <.detail_row label="HSN / SAC Code" value={@selected.code} />
            <.detail_row label="Description" value={@selected.description} />
            <.detail_row label="GST Rate" value={"#{@selected.rate}%"} />
            <.detail_row label="IGST Rate" value={"#{@selected.igst}%"} />
            <.detail_row label="CGST Rate" value={"#{@selected.cgst}%"} />
            <.detail_row label="SGST Rate" value={"#{@selected.sgst}%"} />
            <.detail_row
              label="Cess"
              value={if @selected.cess == 0, do: "NIL", else: "#{@selected.cess}%"}
            /> <.detail_row label="Effective From" value={format_date(@selected.effective_from)} />
            <div class="mt-4 flex items-center justify-between border-t border-base-300 pt-4 text-sm text-base-content/45">
              <span>Source: {@selected.source}</span>
              <a
                href="https://www.cbic.gov.in"
                target="_blank"
                rel="noopener noreferrer"
                class={secondary_button_class()}
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-4" /> View Details
              </a>
            </div>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp detail_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4 py-1.5 text-sm">
      <span class="text-base-content/60">{@label}</span>
      <span class="text-right font-medium">{@value}</span>
    </div>
    """
  end

  defp search(:keyword, query), do: HsnFinder.search_by_keyword(query)
  defp search(:code, query), do: HsnFinder.search_by_code(query)
end
