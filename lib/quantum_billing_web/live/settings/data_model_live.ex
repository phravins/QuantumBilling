defmodule QuantumBillingWeb.SettingsLive.DataModel do
  @moduledoc """
  Owner-only: the business's own fields on clients, invoices and other records.

  One tab per object. Fields can be added, edited, reordered and archived;
  archived ones keep their values and can be restored, or deleted once no
  record holds a value.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.CustomFieldComponents
  import QuantumBillingWeb.SettingsComponents, only: [toggle: 1]

  alias QuantumBilling.CustomFields
  alias QuantumBilling.CustomFields.FieldDefinition

  @objects Enum.map(CustomFields.objects(), &elem(&1, 0))

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Data model")
     |> assign(:objects, CustomFields.objects())
     |> assign(:object, "client")
     |> assign(:dialog, nil)
     |> stream_configure(:fields, dom_id: &"field-#{&1.id}")
     |> stream_configure(:archived, dom_id: &"archived-field-#{&1.id}")}
  end

  def handle_params(params, _uri, socket) do
    object = if params["object"] in @objects, do: params["object"], else: "client"

    {:noreply, socket |> assign(:object, object) |> assign(:dialog, nil) |> load()}
  end

  defp load(socket) do
    object = socket.assigns.object
    fields = CustomFields.list_definitions(object)
    archived = CustomFields.list_definitions(object, archived: :only)

    socket
    |> assign(:counts, CustomFields.active_counts())
    |> assign(:field_count, length(fields))
    |> assign(:archived_count, length(archived))
    |> assign(:first_id, fields |> List.first() |> then(&(&1 && &1.id)))
    |> assign(:last_id, fields |> List.last() |> then(&(&1 && &1.id)))
    |> stream(:fields, fields, reset: true)
    |> stream(:archived, archived, reset: true)
  end

  ## The add/edit dialog

  def handle_event("new", _params, socket) do
    if socket.assigns.field_count >= CustomFields.max_active() do
      {:noreply,
       put_flash(
         socket,
         :error,
         "A record type can have at most #{CustomFields.max_active()} fields."
       )}
    else
      definition = %FieldDefinition{object: socket.assigns.object}
      {:noreply, open_dialog(socket, definition, %{})}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    with_definition(socket, id, &open_dialog(socket, &1, %{}))
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :dialog, nil)}

  def handle_event("validate", %{"field" => params}, socket) do
    {:noreply, put_dialog_form(socket, params, :validate)}
  end

  def handle_event("add_choice", _params, socket) do
    choices = socket.assigns.dialog.choices ++ [%{"id" => "", "label" => "", "color" => "gray"}]
    {:noreply, update_dialog(socket, choices: choices)}
  end

  def handle_event("remove_choice", %{"index" => index}, socket) do
    choices = List.delete_at(socket.assigns.dialog.choices, to_index(index))
    params = Map.put(socket.assigns.dialog.params, "choices", index_choices(choices))
    {:noreply, put_dialog_form(socket, params, :validate)}
  end

  def handle_event("save", %{"field" => params}, socket) do
    %{definition: definition} = socket.assigns.dialog
    scope = socket.assigns.current_scope

    result =
      if definition.id,
        do: CustomFields.update_definition(scope, definition, params),
        else: CustomFields.create_definition(scope, definition.object, params)

    case result do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{saved.label} saved.")
         |> assign(:dialog, nil)
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_dialog_form(socket, params, Map.put(changeset, :action, :validate))}

      {:error, reason} ->
        {:noreply, socket |> assign(:dialog, nil) |> put_flash(:error, problem(reason)) |> load()}
    end
  end

  ## Row actions

  def handle_event("move", %{"id" => id, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    with_definition(socket, id, fn definition ->
      case CustomFields.move(
             socket.assigns.current_scope,
             definition,
             String.to_existing_atom(direction)
           ) do
        {:ok, _definition} -> load(socket)
        {:error, reason} -> put_flash(socket, :error, problem(reason))
      end
    end)
  end

  def handle_event("archive", %{"id" => id}, socket) do
    with_definition(socket, id, fn definition ->
      case CustomFields.archive_definition(socket.assigns.current_scope, definition) do
        {:ok, archived} -> socket |> put_flash(:info, "#{archived.label} archived.") |> load()
        {:error, reason} -> put_flash(socket, :error, problem(reason))
      end
    end)
  end

  def handle_event("restore", %{"id" => id}, socket) do
    with_definition(socket, id, fn definition ->
      case CustomFields.restore_definition(socket.assigns.current_scope, definition) do
        {:ok, restored} -> socket |> put_flash(:info, "#{restored.label} restored.") |> load()
        {:error, reason} -> put_flash(socket, :error, problem(reason))
      end
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with_definition(socket, id, fn definition ->
      case CustomFields.delete_definition(socket.assigns.current_scope, definition) do
        {:ok, deleted} -> socket |> put_flash(:info, "#{deleted.label} deleted.") |> load()
        {:error, reason} -> socket |> put_flash(:error, problem(reason)) |> load()
      end
    end)
  end

  # Only definitions of the open tab: an id from another tab is treated as stale.
  defp with_definition(socket, id, fun) do
    case CustomFields.get_definition(id) do
      %FieldDefinition{object: object} = definition when object == socket.assigns.object ->
        {:noreply, fun.(definition)}

      _missing ->
        {:noreply, socket |> put_flash(:error, "That field no longer exists.") |> load()}
    end
  end

  defp open_dialog(socket, definition, params) do
    in_use? = not is_nil(definition.id) and CustomFields.in_use?(definition)

    socket
    |> assign(:dialog, %{
      definition: definition,
      in_use?: in_use?,
      params: params,
      choices: FieldDefinition.choices(definition),
      form: nil
    })
    |> put_dialog_form(params, nil)
  end

  # `action` nil means nothing typed yet, so no errors show.
  defp put_dialog_form(socket, params, action) do
    dialog = socket.assigns.dialog

    changeset =
      case action do
        %Ecto.Changeset{} = changeset ->
          changeset

        action ->
          dialog.definition
          |> CustomFields.change_definition(params)
          |> Map.put(:action, action)
      end

    choices =
      case params do
        %{"choices" => choices} when is_map(choices) ->
          choices
          |> Enum.sort_by(fn {index, _row} -> to_index(index) end)
          |> Enum.map(fn {_index, row} -> row end)

        _not_sent ->
          dialog.choices
      end

    update_dialog(socket,
      params: params,
      choices: choices,
      form: to_form(changeset, as: :field)
    )
  end

  defp update_dialog(socket, changes) do
    assign(socket, :dialog, Enum.into(changes, socket.assigns.dialog))
  end

  defp to_index(index) do
    case Integer.parse(to_string(index)) do
      {number, ""} -> number
      _other -> -1
    end
  end

  defp blank_to(value, fallback) when value in [nil, ""], do: fallback
  defp blank_to(value, _fallback), do: value

  defp index_choices(choices) do
    choices |> Enum.with_index() |> Map.new(fn {row, index} -> {to_string(index), row} end)
  end

  defp problem(:unauthorized), do: "Only owners can change the data model."

  defp problem(:limit_reached),
    do: "A record type can have at most #{CustomFields.max_active()} fields."

  defp problem(:in_use),
    do: "Records still hold values for this field, so it can only be archived."

  defp problem(:not_archived), do: "Archive the field before deleting it."
  defp problem(_other), do: "That didn't work. Try again."

  ## Template helpers

  # Once records hold values, only the type changes that keep them readable are offered.
  defp type_choices(%{in_use?: true, definition: %{type: type}}) do
    allowed =
      case type do
        "text" -> ~w(text long_text)
        "long_text" -> ~w(long_text text)
        "select" -> ~w(select multi_select)
        other -> [other]
      end

    Enum.filter(type_options(), fn {_label, value} -> value in allowed end)
  end

  defp type_choices(_dialog), do: type_options()

  defp form_type(form), do: to_string(form[:type].value || "text")

  defp default_value(dialog, form) do
    case Map.fetch(dialog.params, "default") do
      {:ok, value} ->
        value

      :error ->
        value = FieldDefinition.default(dialog.definition)
        if form_type(form) == "money", do: value && money_input(value), else: value
    end
  end

  defp option_errors(form) do
    if form.source.action,
      do: Enum.map(Keyword.get_values(form.errors, :options), &elem(&1, 0)),
      else: []
  end

  defp object_label(objects, object) do
    Enum.find_value(objects, object, fn {key, label} -> if key == object, do: label end)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:settings}
      active_sub={:"data-model"}
    >
      <.header>
        Data model
        <:subtitle>
          Add your own fields to records, such as a PO number on invoices or a sales region on
          clients. Your team fills them in; you decide where they show.
        </:subtitle>
      </.header>

      <nav
        id="data-model-objects"
        class="-mx-1 mb-4 flex gap-1 overflow-x-auto px-1 pb-1"
        aria-label="Record types"
      >
        <.link
          :for={{object, label} <- @objects}
          id={"object-tab-#{object}"}
          patch={~p"/settings/data-model?#{[object: object]}"}
          aria-current={if object == @object, do: "page"}
          class={[
            "flex shrink-0 items-center gap-1.5 rounded-field border px-3 py-1.5 text-sm transition-all duration-150",
            if(object == @object,
              do: "border-base-content bg-base-content text-base-100 shadow-sm",
              else:
                "border-base-300 bg-base-100 text-base-content/70 hover:border-base-content/30 hover:text-base-content"
            )
          ]}
        >
          {label}
          <span
            :if={Map.get(@counts, object, 0) > 0}
            class={[
              "rounded-full px-1.5 text-[11px] tabular-nums",
              if(object == @object, do: "bg-base-100/20", else: "bg-base-200")
            ]}
          >
            {Map.get(@counts, object, 0)}
          </span>
        </.link>
      </nav>

      <.card class="mb-4" padding="p-0">
        <div class="flex flex-col gap-3 border-b border-base-300 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h3 class="text-sm font-semibold">{object_label(@objects, @object)} fields</h3>
            <p class="text-xs text-base-content/60">
              <span class="tabular-nums">{@field_count}</span>
              of {CustomFields.max_active()} · shown in this order on forms
            </p>
          </div>

          <button
            id="new-field"
            type="button"
            phx-click="new"
            disabled={@field_count >= CustomFields.max_active()}
            class={[action_button_class(), "disabled:cursor-not-allowed disabled:opacity-40"]}
          >
            <.icon name="hero-plus" class="size-4" /> Add field
          </button>
        </div>

        <ul id="fields" phx-update="stream" class="divide-y divide-base-300">
          <li id="fields-empty" class="hidden only:block">
            <.empty_state
              icon="hero-table-cells"
              title={"No fields on #{String.downcase(object_label(@objects, @object))} yet"}
              description="Fields you add appear on the form for every record of this type."
            />
          </li>

          <li
            :for={{dom_id, field} <- @streams.fields}
            id={dom_id}
            class="group flex items-center gap-3 px-4 py-2.5 transition-colors hover:bg-base-200/50"
          >
            <div class="flex shrink-0 flex-col">
              <button
                id={"move-up-#{field.id}"}
                type="button"
                phx-click="move"
                phx-value-id={field.id}
                phx-value-direction="up"
                disabled={field.id == @first_id}
                aria-label={"Move #{field.label} up"}
                class="flex size-5 items-center justify-center rounded text-base-content/40 transition-colors hover:bg-base-200 hover:text-base-content disabled:invisible"
              >
                <.icon name="hero-chevron-up" class="size-3.5" />
              </button>
              <button
                id={"move-down-#{field.id}"}
                type="button"
                phx-click="move"
                phx-value-id={field.id}
                phx-value-direction="down"
                disabled={field.id == @last_id}
                aria-label={"Move #{field.label} down"}
                class="flex size-5 items-center justify-center rounded text-base-content/40 transition-colors hover:bg-base-200 hover:text-base-content disabled:invisible"
              >
                <.icon name="hero-chevron-down" class="size-3.5" />
              </button>
            </div>

            <span class="flex size-8 shrink-0 items-center justify-center rounded-field bg-base-200 text-base-content/60">
              <.icon name={type_icon(field.type)} class="size-4" />
            </span>

            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
                <span class="truncate text-sm font-medium">{field.label}</span>
                <span :if={field.required} class="text-[11px] font-medium text-error">Required</span>
              </div>
              <div class="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1">
                <.type_tag type={field.type} />
                <code class="font-mono text-[11px] text-base-content/45">{field.key}</code>
                <span
                  :if={field.show_in_list}
                  class="rounded-field bg-base-200 px-1.5 py-0.5 text-[11px] text-base-content/70"
                >
                  List column
                </span>
                <span
                  :if={field.filterable}
                  class="rounded-field bg-base-200 px-1.5 py-0.5 text-[11px] text-base-content/70"
                >
                  Filter
                </span>
                <span
                  :if={field.show_on_invoice}
                  class="rounded-field bg-base-200 px-1.5 py-0.5 text-[11px] text-base-content/70"
                >
                  On invoice
                </span>
                <span
                  :if={not field.include_in_api}
                  class="rounded-field bg-warning/15 px-1.5 py-0.5 text-[11px] text-warning"
                >
                  Hidden from API
                </span>
              </div>
              <div :if={FieldDefinition.choices(field) != []} class="mt-1.5 flex flex-wrap gap-1">
                <.choice_badge
                  :for={choice <- Enum.take(FieldDefinition.choices(field), 8)}
                  choice={choice}
                />
                <span
                  :if={length(FieldDefinition.choices(field)) > 8}
                  class="text-[11px] text-base-content/45"
                >
                  +{length(FieldDefinition.choices(field)) - 8} more
                </span>
              </div>
            </div>

            <div class="flex shrink-0 gap-1 opacity-100 transition-opacity sm:opacity-60 sm:group-hover:opacity-100">
              <button
                id={"edit-field-#{field.id}"}
                type="button"
                phx-click="edit"
                phx-value-id={field.id}
                class="btn btn-xs btn-ghost"
              >
                Edit
              </button>
              <button
                id={"archive-field-#{field.id}"}
                type="button"
                phx-click="archive"
                phx-value-id={field.id}
                data-confirm={"Archive #{field.label}? It leaves forms and lists; saved values are kept."}
                class="btn btn-xs btn-ghost"
              >
                Archive
              </button>
            </div>
          </li>
        </ul>
      </.card>

      <details :if={@archived_count > 0} id="archived-fields" class="group/archived">
        <summary class="mb-2 flex cursor-pointer list-none items-center gap-1.5 text-xs font-medium text-base-content/60 transition-colors hover:text-base-content">
          <.icon
            name="hero-chevron-right"
            class="size-3.5 transition-transform duration-150 group-open/archived:rotate-90"
          /> Archived ({@archived_count})
        </summary>

        <.card padding="p-0">
          <ul id="archived" phx-update="stream" class="divide-y divide-base-300">
            <li
              :for={{dom_id, field} <- @streams.archived}
              id={dom_id}
              class="flex items-center gap-3 px-4 py-2.5"
            >
              <span class="flex size-8 shrink-0 items-center justify-center rounded-field bg-base-200 text-base-content/40">
                <.icon name={type_icon(field.type)} class="size-4" />
              </span>
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm text-base-content/70">{field.label}</p>
                <code class="font-mono text-[11px] text-base-content/45">{field.key}</code>
              </div>
              <div class="flex shrink-0 gap-1">
                <button
                  id={"restore-field-#{field.id}"}
                  type="button"
                  phx-click="restore"
                  phx-value-id={field.id}
                  class="btn btn-xs btn-ghost"
                >
                  Restore
                </button>
                <button
                  id={"delete-field-#{field.id}"}
                  type="button"
                  phx-click="delete"
                  phx-value-id={field.id}
                  data-confirm={"Delete #{field.label} for good? This can't be undone."}
                  class="btn btn-xs btn-ghost text-error"
                >
                  Delete
                </button>
              </div>
            </li>
          </ul>
        </.card>
      </details>

      <.field_dialog :if={@dialog} dialog={@dialog} objects={@objects} />
    </Layouts.app>
    """
  end

  attr :dialog, :map, required: true
  attr :objects, :list, required: true

  defp field_dialog(assigns) do
    assigns =
      assigns
      |> assign(:form, assigns.dialog.form)
      |> assign(:type, form_type(assigns.dialog.form))
      |> assign(:definition, assigns.dialog.definition)

    ~H"""
    <div
      id="field-dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="field-dialog-title"
      class="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto p-4"
      phx-window-keydown="close"
      phx-key="escape"
    >
      <div class="fixed inset-0 bg-base-content/30 backdrop-blur-sm" phx-click="close" />

      <div class="relative max-h-[calc(100dvh-2rem)] w-full max-w-lg overflow-y-auto rounded-box border border-base-300 bg-base-100 p-5 shadow-xl">
        <div class="mb-4 flex items-start justify-between gap-3">
          <div>
            <h2 id="field-dialog-title" class="text-sm font-semibold tracking-tight">
              <%= if @definition.id do %>
                Edit {@definition.label}
              <% else %>
                Add a field to {object_label(@objects, @definition.object)}
              <% end %>
            </h2>
            <p :if={@definition.id} class="mt-0.5 text-xs text-base-content/60">
              Key <code class="font-mono">{@definition.key}</code>
              is used in the API and exports, and stays the same if you rename the field.
            </p>
          </div>

          <button
            type="button"
            phx-click="close"
            class="flex size-7 items-center justify-center rounded-field text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <.form for={@form} id="field-form" phx-change="validate" phx-submit="save">
          <div class="space-y-3">
            <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <.input
                field={@form[:label]}
                type="text"
                label="Label"
                maxlength="60"
                placeholder="e.g. PO number"
                phx-mounted={JS.focus()}
                required
              />
              <.input
                field={@form[:type]}
                type="select"
                label="Type"
                options={type_choices(@dialog)}
              />
            </div>
            <p :if={@dialog.in_use?} class="-mt-1 text-xs text-base-content/50">
              Records already hold values, so the type can only change to one that keeps them.
            </p>

            <.input
              field={@form[:help_text]}
              type="text"
              label="Help text (optional)"
              maxlength="200"
              placeholder="Shown under the field on forms"
            />

            <fieldset :if={FieldDefinition.choice_type?(@type)} id="field-choices">
              <legend class="mb-1.5 text-xs font-medium text-base-content/70">Choices</legend>
              <div class="space-y-1.5">
                <div
                  :for={{choice, index} <- Enum.with_index(@dialog.choices)}
                  id={"choice-row-#{index}"}
                  class="flex items-center gap-2"
                >
                  <input type="hidden" name={"field[choices][#{index}][id]"} value={choice["id"]} />
                  <select
                    id={"choice-color-#{index}"}
                    name={"field[choices][#{index}][color]"}
                    aria-label="Colour"
                    class={[
                      "h-8 w-24 shrink-0 cursor-pointer rounded-field border border-base-300 px-2 text-xs",
                      color_class(choice["color"])
                    ]}
                  >
                    <option
                      :for={color <- FieldDefinition.colors()}
                      value={color}
                      selected={choice["color"] == color}
                    >
                      {String.capitalize(color)}
                    </option>
                  </select>
                  <input
                    type="text"
                    id={"choice-label-#{index}"}
                    name={"field[choices][#{index}][label]"}
                    value={choice["label"]}
                    maxlength="60"
                    placeholder={"Choice #{index + 1}"}
                    phx-debounce="300"
                    class="h-8 min-w-0 flex-1 rounded-field border border-base-300 bg-base-100 px-2.5 text-sm transition-colors focus:border-base-content/40 focus:outline-none"
                  />
                  <button
                    id={"remove-choice-#{index}"}
                    type="button"
                    phx-click="remove_choice"
                    phx-value-index={index}
                    aria-label="Remove choice"
                    class="flex size-7 shrink-0 items-center justify-center rounded-field text-base-content/40 transition-colors hover:bg-error/10 hover:text-error"
                  >
                    <.icon name="hero-x-mark" class="size-3.5" />
                  </button>
                </div>
              </div>
              <button
                id="add-choice"
                type="button"
                phx-click="add_choice"
                class="mt-2 inline-flex items-center gap-1 rounded-field px-1.5 py-1 text-xs font-medium text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-plus" class="size-3.5" /> Add choice
              </button>
            </fieldset>

            <.default_input
              type={@type}
              value={default_value(@dialog, @form)}
              choices={@dialog.choices}
            />

            <p :for={message <- option_errors(@form)} class="qb-field-error text-xs text-error">
              {message}
            </p>

            <div class="space-y-2 pt-1">
              <p class="text-xs font-medium text-base-content/70">Where it appears</p>
              <.toggle
                :if={@type != "boolean"}
                field={@form[:required]}
                label="Required"
                hint="A record can't be saved without it."
              />
              <.toggle
                :if={FieldDefinition.listed_object?(@definition.object)}
                field={@form[:show_in_list]}
                label="Column in the list"
                hint="Shown as a column on the list page."
              />
              <.toggle
                :if={
                  FieldDefinition.listed_object?(@definition.object) and
                    FieldDefinition.filterable_type?(@type)
                }
                field={@form[:filterable]}
                label="Filter"
                hint="Offered as a filter on the list page."
              />
              <.toggle
                :if={FieldDefinition.printable_object?(@definition.object)}
                field={@form[:show_on_invoice]}
                label="Printable on invoices"
                hint={
                  if(@definition.object == "invoice_item",
                    do: "Printed as an item-table column when a line has a value.",
                    else: "Available to the invoice designer's custom-fields block."
                  )
                }
              />
              <.toggle
                field={@form[:include_in_api]}
                label="Included in the API"
                hint="Sent in API responses and accepted when records are created through the API."
              />
            </div>
          </div>

          <div class="mt-5 flex justify-end gap-2">
            <button type="button" phx-click="close" class={secondary_button_class()}>
              Cancel
            </button>
            <button
              id="save-field"
              type="submit"
              phx-disable-with="Saving…"
              class={action_button_class()}
            >
              {if @definition.id, do: "Save field", else: "Add field"}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :type, :string, required: true
  attr :value, :any, default: nil
  attr :choices, :list, default: []

  defp default_input(%{type: "multi_select"} = assigns), do: ~H""

  defp default_input(%{type: type} = assigns) when type in ["select", "boolean"] do
    options =
      if type == "boolean",
        do: [{"Yes", "true"}, {"No", "false"}],
        else:
          for(
            choice <- assigns.choices,
            String.trim(choice["label"] || "") != "",
            do: {choice["label"], blank_to(choice["id"], choice["label"])}
          )

    assigns = assign(assigns, :options, options)

    ~H"""
    <.input
      type="select"
      id="field-default"
      name="field[default]"
      label="Default (optional)"
      value={to_string(@value || "")}
      options={@options}
      prompt="No default"
    />
    """
  end

  defp default_input(assigns) do
    assigns =
      assign(assigns,
        input_type:
          case assigns.type do
            "date" -> "date"
            "long_text" -> "textarea"
            _other -> "text"
          end
      )

    ~H"""
    <.input
      type={@input_type}
      id="field-default"
      name="field[default]"
      label="Default (optional)"
      value={@value}
      placeholder="Prefilled on new records"
    />
    """
  end
end
