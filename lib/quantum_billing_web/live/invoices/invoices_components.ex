defmodule QuantumBillingWeb.InvoicesComponents do
  @moduledoc """
  UI building blocks specific to the Invoices list page: a clickable,
  sort-indicating table header and windowed pagination controls.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders a clickable `<th>` label that toggles sorting for `field` and shows
  the current sort direction when it is the active sort column.
  """
  attr :label, :string, required: true
  attr :field, :atom, required: true
  attr :current_field, :atom, required: true
  attr :current_dir, :atom, required: true

  def sortable_th(assigns) do
    ~H"""
    <button
      type="button"
      class="inline-flex items-center gap-1 font-semibold hover:text-primary"
      phx-click="sort"
      phx-value-field={@field}
    >
      {@label}
      <.icon
        :if={@current_field == @field and @current_dir == :asc}
        name="hero-chevron-up"
        class="size-3.5"
      />
      <.icon
        :if={@current_field == @field and @current_dir == :desc}
        name="hero-chevron-down"
        class="size-3.5"
      />
      <.icon
        :if={@current_field != @field}
        name="hero-chevron-up-down"
        class="size-3.5 text-base-content/30"
      />
    </button>
    """
  end

  @doc """
  Renders prev/next chevrons plus a windowed set of page number buttons
  (e.g. `1 2 3 ... 10`) around the current page.
  """
  attr :current_page, :integer, required: true
  attr :total_pages, :integer, required: true

  def pagination(assigns) do
    assigns = assign(assigns, :window, page_window(assigns.current_page, assigns.total_pages))

    ~H"""
    <div class="flex items-center gap-1">
      <button
        type="button"
        class="btn btn-ghost btn-sm"
        disabled={@current_page == 1}
        phx-click="paginate"
        phx-value-page={@current_page - 1}
      >
        <.icon name="hero-chevron-left" class="size-4" />
      </button>
      <%= for entry <- @window do %>
        <span :if={entry == :ellipsis} class="px-2 text-base-content/40">...</span>
        <button
          :if={entry != :ellipsis}
          type="button"
          class={[
            "btn btn-sm",
            entry == @current_page && "btn-primary",
            entry != @current_page && "btn-ghost"
          ]}
          phx-click="paginate"
          phx-value-page={entry}
        >
          {entry}
        </button>
      <% end %>
      <button
        type="button"
        class="btn btn-ghost btn-sm"
        disabled={@current_page == @total_pages}
        phx-click="paginate"
        phx-value-page={@current_page + 1}
      >
        <.icon name="hero-chevron-right" class="size-4" />
      </button>
    </div>
    """
  end

  defp page_window(_current, total) when total <= 5, do: Enum.to_list(1..total)

  defp page_window(current, total) do
    cond do
      current <= 3 -> [1, 2, 3, :ellipsis, total]
      current >= total - 2 -> [1, :ellipsis, total - 2, total - 1, total]
      true -> [1, :ellipsis, current - 1, current, current + 1, :ellipsis, total]
    end
  end
end
