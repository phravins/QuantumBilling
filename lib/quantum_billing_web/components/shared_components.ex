defmodule QuantumBillingWeb.SharedComponents do
  @moduledoc """
  UI building blocks shared across more than one feature folder: status pills,
  summary tiles, the labelled form field, and the generic table controls
  (sortable headers, pagination) used by every paginated list page.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1, input: 1]

  @action_button_class "inline-flex h-9 items-center gap-2 rounded-field bg-primary px-3.5 " <>
                         "text-sm font-medium text-primary-content transition-colors " <>
                         "hover:bg-primary/90"

  @secondary_button_class "inline-flex h-9 items-center gap-2 rounded-field border " <>
                            "border-base-300 bg-base-100 px-3 text-sm text-base-content/60 " <>
                            "transition-colors hover:bg-base-200 hover:text-base-content"

  # The toolbar controls run a size below the page-header buttons: they sit
  # above every list and repeat on every page, so the height they take is
  # height the list itself does not get.
  @filter_input_class "h-8 w-full rounded-field border border-base-300 bg-base-100 pl-8 pr-3 " <>
                        "text-xs placeholder:text-base-content/45 focus:outline-none " <>
                        "focus:ring-2 focus:ring-base-content/10"

  @filter_button_class "inline-flex h-8 items-center gap-1.5 rounded-field border " <>
                         "border-base-300 bg-base-100 px-2.5 text-xs text-base-content/60 " <>
                         "transition-colors hover:bg-base-200 hover:text-base-content"

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

  # `[&>th]:py-1.5` sets the header's height from here rather than cell by cell.
  # daisyUI's own `.table` padding is 0.75rem top and bottom, which on a row of
  # 10px uppercase labels is most of the row's height; the arbitrary variant
  # outranks it because daisyUI wraps its rules in zero-specificity `:where()`.
  # Horizontal padding is left alone — only the height was too generous.
  # `font-semibold` and a darker tint than the rows beneath: at this size the
  # labels were reading as the same weight as the data they head.
  @table_head_class "border-b border-base-300 text-xs font-semibold uppercase tracking-wider " <>
                      "text-base-content/60 [&>th]:py-1.5"

  @table_row_class "border-b border-base-300 text-sm last:border-0 hover:bg-base-200/60"

  @doc "The solid, near-black call-to-action button used in page headers."
  def action_button_class, do: @action_button_class

  @doc "The outlined companion to `action_button_class/0`, for toolbar controls."
  def secondary_button_class, do: @secondary_button_class

  @doc "The search field used by the list-page toolbars (leaves room for a leading icon)."
  def filter_input_class, do: @filter_input_class

  @doc "The compact button beside `filter_input_class/0`; a size down from `secondary_button_class/0`."
  def filter_button_class, do: @filter_button_class

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
  attr :padding, :string, default: "p-4"
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
  Renders the QuantumBilling mark: the bare icon with the wordmark beside it.

  Shared because it appears both in the sidebar and at the head of the
  documents the app produces, and a mark that drifts between the two stops
  reading as one product.

  ## Examples

      <.brand_mark />
      <.brand_mark icon_class="size-5" label_class="text-base font-semibold" />
  """
  attr :class, :any, default: nil
  attr :icon_class, :any, default: "size-6"
  attr :label_class, :any, default: "text-sm font-semibold tracking-tight"

  def brand_mark(assigns) do
    ~H"""
    <div class={["flex items-center gap-2", @class]}>
      <.icon name="hero-receipt-percent" class={["shrink-0", @icon_class]} />
      <span class={["truncate", @label_class]}>QuantumBilling</span>
    </div>
    """
  end

  @doc """
  Renders a small arrow that opens a panel of supporting copy when clicked.

  Guidance worth reading once but not worth a permanent column — the "what this
  page is for" blurb and the tips beside it — lives here instead of in a
  sidebar, so the form itself gets the full width of the page.

  Driven by a hidden checkbox the chevron labels, deliberately *not* by the
  daisyUI dropdown the filter menus use: that one opens on `:focus-within`, and
  with the trigger in the tab order the panel sprang open whenever focus
  happened to reach it rather than when anyone asked for it. Only a click on the
  chevron opens this. A hook closes it on an outside click or Escape, which
  focus-driven dropdowns get for free and this does not.

  It renders as `<span>`s because the usual home for it is inside `header/1`'s
  `<h1>`, which only accepts phrasing content.

  ## Examples

      <.header>
        <span class="inline-flex items-center gap-2">
          Add New Client
          <.help_popover id="client-help" label="About adding a client">…</.help_popover>
        </span>
      </.header>
  """
  attr :id, :string, required: true

  attr :label, :string,
    default: "More information",
    doc: "the accessible name for the icon-only trigger"

  attr :class, :any, default: nil

  slot :inner_block, required: true

  def help_popover(assigns) do
    ~H"""
    <span class={["group relative inline-flex", @class]}>
      <input type="checkbox" id={@id} class="peer sr-only" phx-hook=".HelpPopover" />
      <label
        for={@id}
        aria-label={@label}
        class={[
          "flex size-6 cursor-pointer items-center justify-center rounded-field",
          "text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
        ]}
      >
        <.icon
          name="hero-chevron-down"
          class="size-4 transition-transform duration-200 group-has-[:checked]:rotate-180"
        />
      </label>
      <%!-- The trigger usually sits in an <h1>, whose type would otherwise cascade in. --%>
      <span class={[
        "invisible absolute left-0 top-full z-20 mt-1 block w-80 space-y-4 opacity-0",
        "rounded-box border border-base-300 bg-base-100 p-4 shadow-lg",
        "text-left text-sm font-normal tracking-normal",
        "transition-opacity duration-150 peer-checked:visible peer-checked:opacity-100"
      ]}>
        {render_slot(@inner_block)}
      </span>
    </span>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".HelpPopover">
      // The chevron opens it; this is only about closing. Without it the panel
      // would sit over the form until you found the chevron again.
      export default {
        mounted() {
          this.onClick = (e) => {
            if (!this.el.parentElement.contains(e.target)) this.el.checked = false
          }
          this.onKey = (e) => {
            if (e.key === "Escape") this.el.checked = false
          }
          document.addEventListener("click", this.onClick)
          document.addEventListener("keydown", this.onKey)
        },

        destroyed() {
          document.removeEventListener("click", this.onClick)
          document.removeEventListener("keydown", this.onKey)
        }
      }
    </script>
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
  # GST compliance obligations.
  defp status_badge_class("Filed"), do: @positive
  defp status_badge_class("Pending"), do: @pending
  defp status_badge_class("Overdue"), do: @negative
  defp status_badge_class(_other), do: @neutral

  @doc """
  Renders a labelled form control with its validation errors.

  Anything not consumed here is forwarded to `CoreComponents.input/1`, so
  `type`, `options`, `prompt`, `placeholder`, `readonly` and friends all work.

  ## Examples

      <.field field={f[:gstin]} label="GSTIN" placeholder="27AABCA1234A1Z5" />
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :required, :boolean, default: false
  attr :hint, :string, default: nil
  attr :class, :any, default: nil
  # `autocomplete` and `spellcheck` matter on the auth forms: without them
  # password managers do not offer to fill or save credentials.
  attr :rest, :global, include: ~w(options prompt placeholder readonly disabled min max step rows
                autocomplete spellcheck)

  def field(assigns) do
    assigns = assign(assigns, :errors, field_errors(assigns.field))

    ~H"""
    <div>
      <label for={@field.id} class="mb-1.5 block text-xs font-medium text-base-content/60">
        {@label}<span :if={@required} class="ml-0.5 text-error">*</span>
      </label>

      <.input
        field={@field}
        type={@type}
        required={@required}
        class={[control_class(@type), @class, @errors != [] && form_error_class()]}
        error_class={form_error_class()}
        {@rest}
      />
      <p :if={@hint && @errors == []} class="mt-1 text-2xs text-base-content/45">{@hint}</p>

      <p :for={msg <- @errors} class="mt-1 flex items-center gap-1 text-2xs text-error">
        <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" /> {msg}
      </p>
    </div>
    """
  end

  defp control_class("select"), do: form_select_class()
  defp control_class("textarea"), do: form_textarea_class()
  defp control_class(_type), do: form_input_class()

  # `input/1` only renders errors for fields the user has touched; mirror that
  # rule here so the two never disagree.
  defp field_errors(%Phoenix.HTML.FormField{} = field) do
    if Phoenix.Component.used_input?(field) do
      Enum.map(field.errors, &translate_field_error/1)
    else
      []
    end
  end

  defp translate_field_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Renders the shared "coming soon" empty-state card used by placeholder pages.
  """
  attr :title, :string, default: "This section is under construction."

  def coming_soon(assigns) do
    ~H"""
    <.card padding="p-12" class="text-center">
      <span class="mx-auto mb-3 flex size-10 items-center justify-center rounded-full bg-base-200 text-base-content/45">
        <.icon name="hero-wrench-screwdriver" class="size-4.5" />
      </span>

      <p class="text-sm text-base-content/60">{@title}</p>
    </.card>
    """
  end

  @doc """
  Renders the "nothing here yet" state a list or panel shows when it has no
  records.

  Unlike `coming_soon/1` this is not a placeholder for unbuilt work: the screen
  is finished, there is simply nothing to show. It renders bare rather than in
  its own card, so it can sit inside the card a table already lives in.

  ## Examples

      <.empty_state title="No invoices yet" description="Create your first GST invoice.">
        <:action>
          <button class={action_button_class()}>Create New GST Invoice</button>
        </:action>
      </.empty_state>
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil

  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class={["flex flex-col items-center px-6 py-14 text-center", @class]}>
      <span class="mb-3 flex size-10 items-center justify-center rounded-full bg-base-200 text-base-content/45">
        <.icon name={@icon} class="size-4.5" />
      </span>

      <p class="text-sm font-medium">{@title}</p>

      <p :if={@description} class="mt-1 max-w-sm text-sm text-base-content/60">{@description}</p>

      <div :if={@action != []} class="mt-4">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  Renders a clickable `<th>` label that toggles sorting for `field`.

  `uppercase` is repeated here even though the header row already sets it: a
  `<button>` does not inherit `text-transform`, which is why these columns read
  "Invoice Date" while the plain ones beside them read "CLIENT".
  """
  attr :label, :string, required: true
  attr :field, :atom, required: true

  def sortable_th(assigns) do
    ~H"""
    <button
      type="button"
      class="inline-flex items-center uppercase hover:text-base-content"
      phx-click="sort"
      phx-value-field={@field}
    >
      {@label}
    </button>
    """
  end

  @page_button_class "inline-flex size-8 items-center justify-center rounded-full border " <>
                       "border-base-300 bg-base-100 text-sm text-base-content/60 " <>
                       "transition-colors hover:bg-base-200 hover:text-base-content " <>
                       "disabled:opacity-40 disabled:pointer-events-none"

  @doc """
  Renders the pager for a list: step back, the page you are on, step forward.

  The page number is an outlined disc rather than a filled one. Filled, it read
  as the primary action on the row when it is not an action at all — it is just
  where you are.
  """
  attr :current_page, :integer, required: true
  attr :total_pages, :integer, required: true

  def pagination(assigns) do
    assigns = assign(assigns, :page_button_class, @page_button_class)

    ~H"""
    <div class="flex items-center gap-1.5">
      <button
        type="button"
        aria-label="Previous page"
        class={@page_button_class}
        disabled={@current_page == 1}
        phx-click="paginate"
        phx-value-page={@current_page - 1}
      >
        <.icon name="hero-chevron-left" class="size-4" />
      </button>

      <span
        aria-current="page"
        aria-label={"Page #{@current_page} of #{@total_pages}"}
        class={[
          "inline-flex size-7 shrink-0 items-center justify-center rounded-full",
          "border border-base-content/70 text-xs font-medium text-base-content"
        ]}
      >
        {@current_page}
      </span>

      <button
        type="button"
        aria-label="Next page"
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
end
