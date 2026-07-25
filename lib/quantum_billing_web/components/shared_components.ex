defmodule QuantumBillingWeb.SharedComponents do
  @moduledoc """
  UI building blocks shared across more than one feature folder: status pills,
  summary tiles, and the generic table controls (sortable headers, pagination)
  used by every paginated list page.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders a colored status pill. Covers both GST invoice statuses and client
  account statuses; anything unrecognized falls back to a neutral pill.
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-soft", status_badge_class(@status)]}>{@status}</span>
    """
  end

  defp status_badge_class("E-Invoice Generated"), do: "badge-success"
  defp status_badge_class("Pending E-Invoice"), do: "badge-warning"
  defp status_badge_class("Draft"), do: "badge-neutral"
  defp status_badge_class("E-Invoice Failed"), do: "badge-error"
  defp status_badge_class("Cancelled"), do: "badge-neutral"
  defp status_badge_class("Active"), do: "badge-success"
  defp status_badge_class("Inactive"), do: "badge-warning"
  defp status_badge_class("Blocked"), do: "badge-error"
  defp status_badge_class(_other), do: "badge-neutral"

  @doc """
  Renders a horizontal summary tile: circular icon badge on the left, with the
  label, value and caption stacked beside it.

  Any additional attributes (e.g. `phx-click`) are forwarded to the underlying
  button, so tiles can double as filter shortcuts.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :caption, :string, default: nil
  attr :icon, :string, required: true
  attr :icon_class, :string, default: "bg-primary/10 text-primary"
  attr :rest, :global

  def metric_card(assigns) do
    ~H"""
    <button
      type="button"
      class="card flex w-full flex-row items-center gap-4 rounded-box border border-base-300 bg-base-100 p-5 text-left hover:border-primary/40"
      {@rest}
    >
      <span class={["flex size-12 shrink-0 items-center justify-center rounded-full", @icon_class]}>
        <.icon name={@icon} class="size-6" />
      </span>
      <span class="min-w-0">
        <span class="block text-sm text-base-content/60">{@label}</span>
        <span class="block text-2xl font-bold">{@value}</span>
        <span :if={@caption} class="block text-xs text-base-content/50">{@caption}</span>
      </span>
    </button>
    """
  end

  @doc """
  Renders the shared "coming soon" empty-state card used by placeholder pages.
  """
  attr :title, :string, default: "This section is under construction."

  def coming_soon(assigns) do
    ~H"""
    <div class="card rounded-box border border-base-300 bg-base-100 p-16 text-center text-base-content/50">
      {@title}
    </div>
    """
  end

  @doc """
  Renders a clickable `<th>` label that toggles sorting for `field` and shows
  the current sort direction when it is the active sort column.
  """
  attr :label, :string, required: true
  attr :field, :atom, required: true
  attr :current_field, :atom, default: nil
  attr :current_dir, :atom, default: :asc

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
