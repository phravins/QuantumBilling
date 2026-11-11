defmodule QuantumBillingWeb.CustomFieldComponents do
  @moduledoc """
  How custom fields look: type names and icons, choice badges, and values shown as text.
  """
  use Phoenix.Component
  use QuantumBillingWeb, :verified_routes

  import QuantumBillingWeb.CoreComponents, only: [icon: 1, input: 1]

  import QuantumBillingWeb.SharedComponents,
    only: [
      filter_button_class: 0,
      form_input_class: 0,
      form_select_class: 0,
      form_textarea_class: 0,
      form_error_class: 0
    ]

  alias QuantumBilling.CustomFields.FieldDefinition
  alias QuantumBillingWeb.Format

  @types %{
    "text" => {"Text", "hero-bars-3-bottom-left"},
    "long_text" => {"Long text", "hero-document-text"},
    "number" => {"Number", "hero-hashtag"},
    "money" => {"Amount", "hero-banknotes"},
    "date" => {"Date", "hero-calendar"},
    "boolean" => {"Yes / No", "hero-check-circle"},
    "select" => {"Single choice", "hero-chevron-up-down"},
    "multi_select" => {"Multiple choice", "hero-list-bullet"},
    "email" => {"Email", "hero-envelope"},
    "phone" => {"Phone", "hero-phone"},
    "url" => {"Web address", "hero-link"}
  }

  @doc "Type options for a select, in the order FieldDefinition lists them."
  def type_options do
    Enum.map(FieldDefinition.types(), &{type_label(&1), &1})
  end

  def type_label(type), do: @types |> Map.get(type, {type, nil}) |> elem(0)
  def type_icon(type), do: @types |> Map.get(type, {nil, "hero-question-mark-circle"}) |> elem(1)

  @doc "Tailwind classes for a choice colour."
  def color_class("blue"), do: "bg-info/12 text-info"
  def color_class("green"), do: "bg-success/12 text-success"
  def color_class("amber"), do: "bg-warning/15 text-warning"
  def color_class("red"), do: "bg-error/12 text-error"
  def color_class("violet"), do: "bg-violet-500/12 text-violet-600 dark:text-violet-300"
  def color_class(_gray), do: "bg-base-200 text-base-content/70"

  @doc "A choice as a coloured pill."
  attr :choice, :map, required: true
  attr :class, :any, default: nil

  def choice_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium",
      color_class(@choice["color"]),
      @class
    ]}>
      {@choice["label"]}
    </span>
    """
  end

  @doc "A field's type as an icon and name."
  attr :type, :string, required: true

  def type_tag(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 text-xs text-base-content/60">
      <.icon name={type_icon(@type)} class="size-3.5" />
      {type_label(@type)}
    </span>
    """
  end

  @doc """
  A stored value as plain text, for lists, exports and documents. Nil when
  there is none. Money shows in `currency` (an ISO code; INR by default).
  """
  def display_value(definition, value, currency \\ nil)

  def display_value(_definition, nil, _currency), do: nil

  def display_value(%FieldDefinition{type: "money"}, minor, currency) when is_integer(minor),
    do: Format.money(minor, currency)

  def display_value(definition, value, _currency), do: display_text(definition, value)

  defp display_text(_definition, nil), do: nil

  defp display_text(%FieldDefinition{type: "boolean"}, true), do: "Yes"
  defp display_text(%FieldDefinition{type: "boolean"}, false), do: "No"

  defp display_text(%FieldDefinition{type: "date"}, iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Format.format_date(date)
      _error -> iso
    end
  end

  defp display_text(%FieldDefinition{type: "select"} = definition, id) when is_binary(id),
    do: FieldDefinition.choice_label(definition, id) || id

  defp display_text(%FieldDefinition{type: "multi_select"} = definition, ids) when is_list(ids) do
    ids |> Enum.map(&(FieldDefinition.choice_label(definition, &1) || &1)) |> Enum.join(", ")
  end

  defp display_text(_definition, value) when is_binary(value), do: value
  defp display_text(_definition, value), do: to_string(value)

  @doc "CSV headers for `definitions`."
  def export_headers(definitions), do: Enum.map(definitions, & &1.label)

  @doc "A record's values for `definitions`, as CSV cells. Money is a plain number."
  def export_cells(definitions, values) do
    values = values || %{}

    Enum.map(definitions, fn definition ->
      case {definition.type, Map.get(values, definition.key)} do
        {"money", paise} when is_integer(paise) -> QuantumBilling.Money.to_input(paise)
        {_type, value} -> display_value(definition, value) || ""
      end
    end)
  end

  @doc """
  A form section with the record's custom fields, headed, with a link to the
  Data model for owners. Renders nothing when the object has no fields.
  """
  attr :id, :string, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :definitions, :list, required: true
  attr :object, :string, required: true
  attr :current_scope, :any, default: nil
  attr :title, :string, default: "Custom Fields"
  attr :class, :any, default: nil
  attr :grid_class, :any, default: "grid grid-cols-1 gap-3 sm:grid-cols-3"

  def custom_fields_section(assigns) do
    ~H"""
    <section :if={@definitions != []} id={@id} class={@class}>
      <div class="mb-2.5 flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold tracking-tight">{@title}</h2>
        <.link
          :if={@current_scope && QuantumBilling.Accounts.Scope.owner?(@current_scope)}
          navigate={~p"/settings/data-model?#{[object: @object]}"}
          class="inline-flex items-center gap-1 text-xs text-base-content/50 transition-colors hover:text-base-content"
        >
          <.icon name="hero-adjustments-horizontal" class="size-3.5" /> Manage fields
        </.link>
      </div>
      <.custom_inputs form={@form} definitions={@definitions} class={@grid_class} />
    </section>
    """
  end

  @doc """
  The inputs for a record's custom fields, inside its form.

  Inputs are named `<form>[custom_fields][<key>]`, which `CustomFields.cast/4`
  reads. A typed value is shown back as typed; otherwise the stored value.
  Errors show once the input was used, or after a failed save.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :definitions, :list, required: true
  attr :class, :any, default: "grid grid-cols-1 gap-3 sm:grid-cols-3"

  def custom_inputs(assigns) do
    ~H"""
    <div :if={@definitions != []} class={@class}>
      <.custom_input :for={definition <- @definitions} definition={definition} form={@form} />
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :definition, FieldDefinition, required: true

  def custom_input(assigns) do
    %{form: form, definition: definition} = assigns
    key = definition.key
    submitted = submitted(form)

    assigns =
      assign(assigns,
        key: key,
        type: definition.type,
        name: "#{form.name}[custom_fields][#{key}]",
        id: "#{form.id}_custom_fields_#{key}",
        value: input_value(definition, submitted, stored(form), new_record?(form)),
        errors: input_errors(form, key, submitted),
        wide?: definition.type in ~w(long_text multi_select)
      )

    ~H"""
    <div class={@wide? && "sm:col-span-full"} id={"#{@id}-wrapper"}>
      <%= if @type == "boolean" do %>
        <label class="flex min-h-9 w-fit cursor-pointer items-center gap-2 pt-5 text-sm">
          <input type="hidden" name={@name} value="false" />
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@value in [true, "true"]}
            class="size-4 accent-base-content"
          />
          {@definition.label}
        </label>
      <% else %>
        <label for={@id} class="mb-1.5 block text-xs font-medium text-base-content/60">
          {@definition.label}<span :if={@definition.required} class="ml-0.5 text-error">*</span>
        </label>

        <%= case @type do %>
          <% "multi_select" -> %>
            <div id={@id} class="flex flex-wrap gap-1.5" role="group">
              <input type="hidden" name={"#{@name}[]"} value="" />
              <label
                :for={choice <- FieldDefinition.choices(@definition)}
                class={[
                  "inline-flex cursor-pointer items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs transition-colors",
                  "border-base-300 hover:border-base-content/30 has-[:checked]:border-base-content/50 has-[:checked]:bg-base-200"
                ]}
              >
                <input
                  type="checkbox"
                  name={"#{@name}[]"}
                  value={choice["id"]}
                  checked={choice["id"] in List.wrap(@value)}
                  class="size-3.5 accent-base-content"
                />
                <.choice_badge choice={choice} />
              </label>
            </div>
            <.custom_errors errors={@errors} />
          <% "select" -> %>
            <.input
              type="select"
              id={@id}
              name={@name}
              value={@value}
              prompt={if(@definition.required, do: "Select…", else: "—")}
              options={Enum.map(FieldDefinition.choices(@definition), &{&1["label"], &1["id"]})}
              errors={@errors}
              class={[form_select_class(), @errors != [] && form_error_class()]}
              error_class={form_error_class()}
            />
          <% "long_text" -> %>
            <.input
              type="textarea"
              id={@id}
              name={@name}
              value={@value}
              rows="3"
              maxlength="5000"
              errors={@errors}
              class={[form_textarea_class(), @errors != [] && form_error_class()]}
              error_class={form_error_class()}
            />
          <% type -> %>
            <.input
              type={html_type(type)}
              id={@id}
              name={@name}
              value={@value}
              errors={@errors}
              class={[form_input_class(), @errors != [] && form_error_class()]}
              error_class={form_error_class()}
              {html_attrs(type)}
            />
        <% end %>
      <% end %>

      <p :if={@definition.help_text && @errors == []} class="mt-1 text-2xs text-base-content/45">
        {@definition.help_text}
      </p>
      <.custom_errors :if={@type == "boolean"} errors={@errors} />
    </div>
    """
  end

  attr :errors, :list, required: true

  defp custom_errors(assigns) do
    ~H"""
    <p
      :for={message <- @errors}
      class="qb-field-error mt-1 flex items-center gap-1 text-2xs text-error"
    >
      <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" /> {message}
    </p>
    """
  end

  defp html_type("date"), do: "date"
  defp html_type("email"), do: "email"
  defp html_type("phone"), do: "tel"
  defp html_type("url"), do: "url"
  defp html_type(_text), do: "text"

  defp html_attrs("number"), do: %{inputmode: "decimal", maxlength: "30"}
  defp html_attrs("money"), do: %{inputmode: "decimal", placeholder: "0.00", maxlength: "20"}
  defp html_attrs("url"), do: %{placeholder: "https://", maxlength: "500"}
  defp html_attrs("email"), do: %{maxlength: "160"}
  defp html_attrs("phone"), do: %{maxlength: "20"}
  defp html_attrs("date"), do: %{}
  defp html_attrs(_text), do: %{maxlength: "500"}

  defp submitted(%Phoenix.HTML.Form{params: %{"custom_fields" => values}}) when is_map(values),
    do: values

  defp submitted(_form), do: nil

  defp stored(%Phoenix.HTML.Form{source: %Ecto.Changeset{} = changeset}),
    do: Ecto.Changeset.get_field(changeset, :custom_fields) || %{}

  defp stored(_form), do: %{}

  # Typed value, else stored value, else (on a record not yet submitted) the default.
  defp input_value(definition, submitted, stored, new?) do
    cond do
      is_map(submitted) and Map.has_key?(submitted, definition.key) ->
        case Map.fetch!(submitted, definition.key) do
          list when is_list(list) -> Enum.reject(list, &(&1 == ""))
          raw -> raw
        end

      Map.has_key?(stored, definition.key) ->
        stored_input(definition, Map.fetch!(stored, definition.key))

      new? and is_nil(submitted) ->
        stored_input(definition, FieldDefinition.default(definition))

      true ->
        nil
    end
  end

  defp new_record?(%Phoenix.HTML.Form{source: %Ecto.Changeset{data: data}}),
    do: is_nil(Map.get(data, :id))

  defp new_record?(_form), do: false

  defp stored_input(%FieldDefinition{type: "money"}, paise) when is_integer(paise),
    do: Format.money_input(paise)

  defp stored_input(%FieldDefinition{type: "multi_select"}, ids), do: List.wrap(ids)
  defp stored_input(_definition, value), do: value

  # While typing, only inputs the person has used; after a failed save, all of them.
  defp input_errors(%Phoenix.HTML.Form{source: %Ecto.Changeset{} = changeset}, key, submitted) do
    used? =
      changeset.action in [:insert, :update] or
        (is_map(submitted) and Map.has_key?(submitted, key) and
           not Map.has_key?(submitted, "_unused_" <> key))

    if changeset.action && used? do
      for {:custom_fields, {message, opts}} <- changeset.errors, opts[:key] == key, do: message
    else
      []
    end
  end

  defp input_errors(_form, _key, _submitted), do: []

  @doc "Whether any of `definitions` has a value in `values`."
  def any_values?(definitions, values) do
    values = values || %{}
    Enum.any?(definitions, &(display_value(&1, Map.get(values, &1.key)) not in [nil, ""]))
  end

  @doc """
  A record's custom fields as label and value pairs, for a detail page.
  Fields without a value are left out; nothing renders when none has one.
  """
  attr :id, :string, required: true
  attr :definitions, :list, required: true
  attr :values, :map, required: true
  attr :currency, :string, default: nil, doc: "for money fields"
  attr :class, :any, default: "grid grid-cols-1 gap-x-6 gap-y-3 sm:grid-cols-2"

  def custom_details(assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        for(
          definition <- assigns.definitions,
          text =
            display_value(
              definition,
              Map.get(assigns.values || %{}, definition.key),
              assigns.currency
            ),
          text not in [nil, ""],
          do: {definition, text}
        )
      )

    ~H"""
    <dl :if={@rows != []} id={@id} class={@class}>
      <div :for={{definition, text} <- @rows} id={"#{@id}-#{definition.key}"} class="min-w-0">
        <dt class="text-xs text-base-content/50">{definition.label}</dt>
        <dd class={[
          "mt-0.5 text-sm break-words",
          definition.type == "long_text" && "whitespace-pre-line",
          definition.type in ~w(money number) && "tabular-nums"
        ]}>
          <%= cond do %>
            <% definition.type == "url" -> %>
              <a
                href={text}
                target="_blank"
                rel="noopener noreferrer nofollow"
                class="underline decoration-base-content/30 underline-offset-2 hover:decoration-base-content"
              >
                {text}
              </a>
            <% definition.type == "email" -> %>
              <a
                href={"mailto:" <> text}
                class="underline decoration-base-content/30 underline-offset-2"
              >
                {text}
              </a>
            <% definition.type in ~w(select multi_select) -> %>
              <span class="flex flex-wrap gap-1">
                <.choice_badge
                  :for={id <- List.wrap(Map.get(@values, definition.key))}
                  choice={FieldDefinition.choice(definition, id) || %{"label" => id}}
                />
              </span>
            <% true -> %>
              {text}
          <% end %>
        </dd>
      </div>
    </dl>
    """
  end

  ## Lists

  @doc "The fields shown as list columns."
  def list_definitions(definitions), do: Enum.filter(definitions, & &1.show_in_list)

  @doc "A record's value in a list cell: choices as badges, everything else as text."
  attr :definition, FieldDefinition, required: true
  attr :values, :map, required: true
  attr :currency, :string, default: nil, doc: "for money fields"

  def custom_cell(assigns) do
    assigns =
      assign(assigns, :value, Map.get(assigns.values || %{}, assigns.definition.key))

    ~H"""
    <%= if @definition.type in ~w(select multi_select) do %>
      <span class="flex flex-wrap gap-1 overflow-hidden">
        <.choice_badge
          :for={id <- List.wrap(@value)}
          choice={FieldDefinition.choice(@definition, id) || %{"label" => id}}
        />
      </span>
    <% else %>
      <span
        class={[
          "block truncate text-base-content/60",
          @definition.type in ~w(money number) && "tabular-nums"
        ]}
        title={display_value(@definition, @value, @currency)}
      >
        {display_value(@definition, @value, @currency)}
      </span>
    <% end %>
    """
  end

  @doc """
  A dropdown per filterable field. Picking an option sends `event` with
  `key` and `value`; an empty `value` clears that filter.
  """
  attr :id, :string, required: true
  attr :definitions, :list, required: true
  attr :filters, :map, required: true
  attr :event, :string, default: "filter_custom"

  def custom_filters(assigns) do
    ~H"""
    <div :if={@definitions != []} id={@id} class="contents">
      <div
        :for={definition <- @definitions}
        id={"#{@id}-#{definition.key}"}
        class="dropdown dropdown-end"
      >
        <div
          tabindex="0"
          role="button"
          class={[
            filter_button_class(),
            Map.has_key?(@filters, definition.key) &&
              "border-primary/40 bg-primary/5 text-base-content"
          ]}
        >
          <.icon name="hero-adjustments-horizontal" class="size-3.5" />
          <span class="max-w-40 truncate">
            {definition.label}<span :if={Map.has_key?(@filters, definition.key)}>: {filter_label(
              definition,
              @filters[definition.key]
            )}</span>
          </span>
          <.icon name="hero-chevron-down" class="size-3.5" />
        </div>

        <ul
          tabindex="0"
          class="dropdown-content menu z-10 mt-2 max-h-72 w-56 flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
        >
          <li :for={{label, value} <- filter_options(definition)}>
            <a
              id={"#{@id}-#{definition.key}-#{if value == "", do: "any", else: value}"}
              phx-click={@event}
              phx-value-key={definition.key}
              phx-value-value={value}
              class={Map.get(@filters, definition.key, "") == value && "menu-active"}
            >
              {label}
            </a>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp filter_options(%FieldDefinition{type: "boolean"}),
    do: [{"Any", ""}, {"Yes", "true"}, {"No", "false"}]

  defp filter_options(definition) do
    [{"Any", ""} | Enum.map(FieldDefinition.choices(definition), &{&1["label"], &1["id"]})]
  end

  defp filter_label(definition, value) do
    Enum.find_value(filter_options(definition), value, fn {label, v} ->
      if v == value, do: label
    end)
  end

  @doc """
  Applies a filter pick to `filters`: a known field and option sets it, an
  empty value clears it, anything else leaves `filters` alone.
  """
  def put_filter(filters, definitions, key, value) do
    definition = Enum.find(definitions, &(&1.key == key))

    cond do
      is_nil(definition) ->
        filters

      value in [nil, ""] ->
        Map.delete(filters, key)

      Enum.any?(filter_options(definition), &(elem(&1, 1) == value)) ->
        Map.put(filters, key, value)

      true ->
        filters
    end
  end
end
