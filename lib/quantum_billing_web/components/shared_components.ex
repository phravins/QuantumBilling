defmodule QuantumBillingWeb.SharedComponents do
  @moduledoc """
  UI building blocks shared across more than one feature folder: status pills,
  summary tiles, and the generic table controls (sortable headers, pagination)
  used by every paginated list page.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1]

  @action_button_class "inline-flex h-9 items-center gap-2 rounded-field bg-primary px-3.5 " <>
                         "text-sm font-medium text-primary-content transition-colors " <>
                         "hover:bg-primary/90"

  @secondary_button_class "inline-flex h-9 items-center gap-2 rounded-field border " <>
                            "border-base-300 bg-base-100 px-3 text-sm text-base-content/60 " <>
                            "transition-colors hover:bg-base-200 hover:text-base-content"

  @filter_input_class "h-9 w-full rounded-field border border-base-300 bg-base-100 pl-9 pr-3 " <>
                        "text-sm placeholder:text-base-content/45 focus:outline-none " <>
                        "focus:ring-2 focus:ring-base-content/10"

  @row_action_class "flex size-7 items-center justify-center rounded-field text-base-content/45 " <>
                      "transition-colors hover:bg-base-200 hover:text-base-content"

  @form_control_base "w-full rounded-field border border-base-300 bg-base-100 px-3 text-sm " <>
                       "text-base-content placeholder:text-base-content/40 focus:outline-none " <>
                       "focus:border-base-content/30 focus:ring-2 focus:ring-base-content/10 " <>
                       "disabled:bg-base-200 disabled:text-base-content/60"

  @form_input_class "h-9 " <> @form_control_base
  @form_select_class "h-9 appearance-none pr-8 " <> @form_control_base
  @form_textarea_class "min-h-24 py-2 " <> @form_control_base
  @form_error_class "border-error focus:border-error focus:ring-error/15"

  @micro_label_class "text-2xs font-medium uppercase tracking-wider text-base-content/45"

  @avatar_class "flex size-7 items-center justify-center rounded-full text-2xs font-semibold"

  @table_head_class "border-b border-base-300 text-2xs font-medium uppercase tracking-wider " <>
                      "text-base-content/45"

  @table_row_class "border-b border-base-300 text-sm last:border-0 hover:bg-base-200/60"

  @doc "The solid, near-black call-to-action button used in page headers."
  def action_button_class, do: @action_button_class

  @doc "The outlined companion to `action_button_class/0`, for toolbar controls."
  def secondary_button_class, do: @secondary_button_class

  @doc "The search field used by the list-page toolbars (leaves room for a leading icon)."
  def filter_input_class, do: @filter_input_class

  @doc "The small, icon-only button used inside table rows."
  def row_action_class, do: @row_action_class

  @doc "A text/date/number input on an app form; same 36px footprint as the toolbar controls."
  def form_input_class, do: @form_input_class

  @doc "A `<select>` on an app form."
  def form_select_class, do: @form_select_class

  @doc "A `<textarea>` on an app form."
  def form_textarea_class, do: @form_textarea_class

  @doc "The invalid state for any of the form controls above."
  def form_error_class, do: @form_error_class

  @doc "The uppercase micro label used for sidebar sections and table headers."
  def micro_label_class, do: @micro_label_class

  @doc "The circular initials chip, shared by the profile menu and the client list."
  def avatar_class, do: @avatar_class

  @doc "The `<tr>` inside `<thead>`; pairs with `table_row_class/0`."
  def table_head_class, do: @table_head_class

  @doc "A body `<tr>`: hairline separator, body type, hover tint."
  def table_row_class, do: @table_row_class

  @doc """
  Renders the surface every panel on the app sits on: a white, hairline-bordered
  box with a whisper of shadow.

  ## Examples

      <.card class="lg:col-span-2" padding="p-6">…</.card>
  """
  attr :class, :any, default: nil
  attr :padding, :string, default: "p-5"
  attr :as, :string, default: "div", doc: "the tag to render, e.g. `button` for clickable tiles"
  attr :rest, :global, include: ~w(type)

  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={@as}
      class={[
        "rounded-box border border-base-300 bg-base-100 shadow-sm",
        @padding,
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  @doc """
  Renders a status pill. Covers both GST invoice statuses and client account
  statuses; anything unrecognized falls back to a neutral pill.

  Colour is deliberately the only chroma left in the data tables, so the pills
  stay soft: tinted background, matching hairline, no fill.
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-medium whitespace-nowrap",
      status_badge_class(@status)
    ]}>{@status}</span>
    """
  end

  @positive "border-emerald-200 bg-emerald-50 text-emerald-700"
  @pending "border-amber-200 bg-amber-50 text-amber-700"
  @negative "border-rose-200 bg-rose-50 text-rose-700"
  @neutral "border-base-300 bg-base-200 text-base-content/60"

  defp status_badge_class("E-Invoice Generated"), do: @positive
  defp status_badge_class("Pending E-Invoice"), do: @pending
  defp status_badge_class("Draft"), do: @neutral
  defp status_badge_class("E-Invoice Failed"), do: @negative
  defp status_badge_class("Cancelled"), do: @neutral
  defp status_badge_class("Active"), do: @positive
  defp status_badge_class("Inactive"), do: @pending
  defp status_badge_class("Blocked"), do: @negative
  defp status_badge_class("Expired"), do: @pending
  defp status_badge_class(_other), do: @neutral

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
  attr :icon_class, :string, default: "bg-base-200 text-base-content/60"
  attr :rest, :global

  def metric_card(assigns) do
    ~H"""
    <.card
      as="button"
      type="button"
      class="flex w-full flex-row items-center gap-4 text-left transition-colors hover:border-base-content/20"
      {@rest}
    >
      <span class={["flex size-10 shrink-0 items-center justify-center rounded-full", @icon_class]}>
        <.icon name={@icon} class="size-4.5" />
      </span>
      <span class="min-w-0">
        <span class="block text-sm text-base-content/60">{@label}</span>
        <span class="block text-2xl font-semibold tracking-tight">{@value}</span>
        <span :if={@caption} class="block text-xs text-base-content/45">{@caption}</span>
      </span>
    </.card>
    """
  end

  @doc """
  Renders the shared "coming soon" empty-state card used by placeholder pages.
  """
  attr :title, :string, default: "This section is under construction."

  def coming_soon(assigns) do
    ~H"""
    <.card padding="p-16" class="text-center">
      <span class="mx-auto mb-3 flex size-10 items-center justify-center rounded-full bg-base-200 text-base-content/45">
        <.icon name="hero-wrench-screwdriver" class="size-4.5" />
      </span>
      <p class="text-sm text-base-content/60">{@title}</p>
    </.card>
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
      class="inline-flex items-center gap-1 hover:text-base-content"
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
        class="size-3.5 text-base-content/45"
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

  @page_button_class "inline-flex size-8 items-center justify-center rounded-field border " <>
                       "border-base-300 bg-base-100 text-sm text-base-content/60 transition-colors " <>
                       "hover:bg-base-200 hover:text-base-content disabled:opacity-40 " <>
                       "disabled:pointer-events-none"

  def pagination(assigns) do
    assigns =
      assigns
      |> assign(:window, page_window(assigns.current_page, assigns.total_pages))
      |> assign(:page_button_class, @page_button_class)

    ~H"""
    <div class="flex items-center gap-1">
      <button
        type="button"
        class={@page_button_class}
        disabled={@current_page == 1}
        phx-click="paginate"
        phx-value-page={@current_page - 1}
      >
        <.icon name="hero-chevron-left" class="size-4" />
      </button>
      <%= for entry <- @window do %>
        <span :if={entry == :ellipsis} class="px-1 text-base-content/45">...</span>
        <button
          :if={entry != :ellipsis}
          type="button"
          class={[
            @page_button_class,
            entry == @current_page && "border-base-content bg-base-content text-base-100"
          ]}
          phx-click="paginate"
          phx-value-page={entry}
        >
          {entry}
        </button>
      <% end %>
      <button
        type="button"
        class={@page_button_class}
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
