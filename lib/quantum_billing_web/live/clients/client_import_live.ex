defmodule QuantumBillingWeb.ClientImportLive do
  @moduledoc """
  Bulk client import from a CSV or Excel file, in three steps: upload the
  file, match its columns to client fields, then review every row and import
  the ready ones.

  The file is read as soon as it arrives and never stored. Rows that already
  exist (same GSTIN or tax number, or same name and phone) are skipped, and
  rows that would fail the client form are listed with the reason, so nothing
  half-valid gets in. The import itself is all or nothing.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Clients
  alias QuantumBilling.Clients.Import
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Spreadsheet

  @steps [{:upload, "Upload file"}, {:mapping, "Match columns"}, {:review, "Review & import"}]

  @sources ["Tally", "Zoho Books", "Vyapar", "QuickBooks", "Busy", "Excel or Google Sheets"]

  def mount(_params, _session, socket) do
    definitions = CustomFields.active_definitions("client")
    regime = socket.assigns.current_scope.tax_regime || "gst"

    {:ok,
     socket
     |> assign(:page_title, "Import clients")
     |> assign(:active_nav, :clients)
     |> assign(:regime, regime)
     |> assign(:definitions, definitions)
     |> assign(:field_options, Import.field_options(definitions))
     |> assign(:required_labels, Import.required_labels(regime, definitions))
     |> assign(:sources, @sources)
     |> assign(:max_rows, Spreadsheet.max_rows())
     |> stream_configure(:rows, dom_id: &"import-row-#{&1.row}")
     |> reset()
     |> allow_upload(:file,
       accept: ~w(.csv .txt .xlsx .xls),
       max_entries: 1,
       max_file_size: Spreadsheet.max_bytes(),
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  defp reset(socket) do
    socket
    |> assign(:step, :upload)
    |> assign(:parse_error, nil)
    |> assign(:file_name, nil)
    |> assign(:headers, [])
    |> assign(:data, [])
    |> assign(:samples, %{})
    |> assign(:mapping, %{})
    |> assign(:mapping_form, to_form(%{}, as: :mapping))
    |> assign(:mapping_errors, [])
    |> assign(:classified, [])
    |> assign(:counts, %{ready: 0, invalid: 0, duplicate: 0})
    |> assign(:filter, "all")
    |> assign(:shown, 0)
    |> assign(:imported, 0)
    |> stream(:rows, [], reset: true)
  end

  # ── Upload ─────────────────────────────────────────────────────────────────

  defp handle_progress(:file, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Spreadsheet.read(path, entry.client_name)}
        end)

      {:noreply, after_parse(socket, entry.client_name, result)}
    else
      {:noreply, socket}
    end
  end

  defp after_parse(socket, file_name, {:ok, %{headers: headers, rows: rows}}) do
    mapping = Import.suggest_mapping(headers, socket.assigns.definitions)

    socket
    |> assign(:step, :mapping)
    |> assign(:parse_error, nil)
    |> assign(:file_name, file_name)
    |> assign(:headers, headers)
    |> assign(:data, rows)
    |> assign(:samples, samples(headers, rows))
    |> put_mapping(mapping)
  end

  defp after_parse(socket, file_name, {:error, message}) do
    socket
    |> assign(:parse_error, message)
    |> assign(:file_name, file_name)
  end

  # Up to two different non-blank values per column, to show what it holds.
  defp samples(headers, rows) do
    for index <- 0..(length(headers) - 1)//1, into: %{} do
      values =
        rows
        |> Stream.map(&Enum.at(&1, index, ""))
        |> Stream.reject(&(&1 == ""))
        |> Stream.uniq()
        |> Enum.take(2)
        |> Enum.map(&truncate(&1, 36))

      {to_string(index), values}
    end
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :file, ref)}
  end

  def handle_event("restart", _params, socket), do: {:noreply, reset(socket)}

  # ── Mapping ────────────────────────────────────────────────────────────────

  def handle_event("map", %{"mapping" => params}, socket) do
    {:noreply, socket |> put_mapping(params) |> assign(:mapping_errors, [])}
  end

  def handle_event("review", %{"mapping" => params}, socket) do
    socket = put_mapping(socket, params)
    %{mapping: mapping, regime: regime, definitions: definitions} = socket.assigns

    case Import.validate_mapping(mapping, regime, definitions) do
      :ok ->
        {:noreply, socket |> classify() |> assign(:step, :review)}

      {:error, messages} ->
        {:noreply, assign(socket, :mapping_errors, messages)}
    end
  end

  def handle_event("back", %{"to" => "mapping"}, socket) do
    {:noreply, assign(socket, :step, :mapping)}
  end

  def handle_event("back", %{"to" => "upload"}, socket), do: {:noreply, reset(socket)}

  # ── Review ─────────────────────────────────────────────────────────────────

  def handle_event("filter", %{"filter" => filter}, socket) when filter in ["all", "problems"] do
    {:noreply, socket |> assign(:filter, filter) |> stream_rows()}
  end

  def handle_event("import", _params, socket) do
    ready = for %{status: :ready, attrs: attrs} <- socket.assigns.classified, do: attrs

    if ready == [] do
      {:noreply, put_flash(socket, :error, "There are no ready rows to import.")}
    else
      opts = [user_id: socket.assigns.current_scope.user.id, file: socket.assigns.file_name]

      case Clients.import_clients(ready, opts) do
        {:ok, clients} ->
          {:noreply, socket |> assign(:imported, length(clients)) |> assign(:step, :done)}

        {:error, changeset} ->
          reason =
            changeset
            |> Import.error_messages(socket.assigns.definitions)
            |> Enum.join(" ")

          {:noreply,
           socket
           |> classify()
           |> put_flash(
             :error,
             "Nothing was imported. #{reason} The rows have been checked again."
           )}
      end
    end
  end

  # Only known columns and known fields; anything else is "Don't import".
  defp put_mapping(socket, params) do
    allowed =
      for {_group, options} <- socket.assigns.field_options,
          {_label, target} <- options,
          into: MapSet.new(),
          do: target

    mapping =
      for index <- 0..(length(socket.assigns.headers) - 1)//1, into: %{} do
        key = to_string(index)
        value = Map.get(params, key, "")
        {key, if(MapSet.member?(allowed, value), do: value, else: "")}
      end

    socket
    |> assign(:mapping, mapping)
    |> assign(:mapping_form, to_form(mapping, as: :mapping))
  end

  defp classify(socket) do
    %{data: data, mapping: mapping, regime: regime, definitions: definitions} = socket.assigns
    classified = Import.classify(data, mapping, regime, definitions)

    counts =
      Enum.reduce(classified, %{ready: 0, invalid: 0, duplicate: 0}, fn row, counts ->
        Map.update!(counts, row.status, &(&1 + 1))
      end)

    filter = if counts.invalid + counts.duplicate == 0, do: "all", else: socket.assigns.filter

    socket
    |> assign(:classified, classified)
    |> assign(:counts, counts)
    |> assign(:filter, filter)
    |> stream_rows()
  end

  defp stream_rows(socket) do
    rows =
      case socket.assigns.filter do
        "problems" -> Enum.reject(socket.assigns.classified, &(&1.status == :ready))
        _all -> socket.assigns.classified
      end

    socket
    |> assign(:shown, length(rows))
    |> stream(:rows, rows, reset: true)
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  def render(assigns) do
    assigns = assign(assigns, :steps, @steps)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <nav class="mb-2 flex items-center gap-1.5 text-xs text-base-content/55" aria-label="Breadcrumb">
        <.link navigate={~p"/clients"} class="transition-colors hover:text-base-content">
          Clients
        </.link>
        <.icon name="hero-chevron-right" class="size-3" />
        <span class="text-base-content/80">Import</span>
      </nav>

      <.header>
        Import clients
        <:subtitle>
          Bring in your whole client list from another app's CSV or Excel export.
        </:subtitle>
      </.header>

      <ol
        id="import-steps"
        class="mb-5 mt-3 flex items-center gap-2 overflow-x-auto pb-1 text-sm"
        aria-label="Import steps"
      >
        <%= for {{key, label}, index} <- Enum.with_index(@steps, 1) do %>
          <li
            id={"import-step-#{key}"}
            class="flex shrink-0 items-center gap-2"
            aria-current={key == @step && "step"}
          >
            <span class={[
              "grid size-6 place-items-center rounded-full text-xs font-semibold transition-colors duration-200",
              step_state(key, @step) == :done && "bg-primary text-primary-content",
              step_state(key, @step) == :current &&
                "bg-primary/12 text-primary ring-2 ring-primary/40",
              step_state(key, @step) == :next && "bg-base-200 text-base-content/50"
            ]}>
              <%= if step_state(key, @step) == :done do %>
                <.icon name="hero-check" class="size-3.5" />
              <% else %>
                {index}
              <% end %>
            </span>
            <span class={[
              "font-medium",
              step_state(key, @step) == :next && "text-base-content/50"
            ]}>
              {label}
            </span>
          </li>
          <li
            :if={index < length(@steps)}
            aria-hidden="true"
            class="h-px w-6 shrink-0 bg-base-300 sm:w-12"
          />
        <% end %>
      </ol>

      <%= case @step do %>
        <% :upload -> %>
          <.upload_step
            uploads={@uploads}
            parse_error={@parse_error}
            file_name={@file_name}
            required_labels={@required_labels}
            sources={@sources}
            max_rows={@max_rows}
          />
        <% :mapping -> %>
          <.mapping_step
            file_name={@file_name}
            headers={@headers}
            row_count={length(@data)}
            samples={@samples}
            mapping={@mapping}
            mapping_form={@mapping_form}
            mapping_errors={@mapping_errors}
            field_options={@field_options}
            required={Import.required_targets(@regime)}
            definitions={@definitions}
          />
        <% :review -> %>
          <.review_step
            file_name={@file_name}
            counts={@counts}
            filter={@filter}
            shown={@shown}
            streams={@streams}
            regime={@regime}
          />
        <% :done -> %>
          <.done_step imported={@imported} counts={@counts} />
      <% end %>
    </Layouts.app>
    """
  end

  defp step_state(_key, :done), do: :done

  defp step_state(key, current) do
    order = Enum.map(@steps, &elem(&1, 0))
    key_index = Enum.find_index(order, &(&1 == key))
    current_index = Enum.find_index(order, &(&1 == current))

    cond do
      key_index < current_index -> :done
      key_index == current_index -> :current
      true -> :next
    end
  end

  # ── Step 1 ─────────────────────────────────────────────────────────────────

  attr :uploads, :map, required: true
  attr :parse_error, :string
  attr :file_name, :string
  attr :required_labels, :list, required: true
  attr :sources, :list, required: true
  attr :max_rows, :integer, required: true

  defp upload_step(assigns) do
    assigns = assign(assigns, :upload, assigns.uploads.file)

    ~H"""
    <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <section class="flex flex-col rounded-box border border-base-300 bg-base-100 p-4 sm:p-5">
        <form
          id="import-upload-form"
          phx-change="validate"
          phx-submit="validate"
          class="flex flex-1 flex-col"
        >
          <label
            id="import-dropzone"
            for={@upload.ref}
            phx-drop-target={@upload.ref}
            class={[
              "group flex min-h-64 flex-1 cursor-pointer flex-col items-center justify-center gap-3",
              "rounded-box border-2 border-dashed border-base-300 bg-base-200/40 px-6 py-12 text-center",
              "transition-all duration-200 hover:border-primary/60 hover:bg-primary/5",
              "phx-drop-target-active:scale-[1.01] phx-drop-target-active:border-primary",
              "phx-drop-target-active:bg-primary/8"
            ]}
          >
            <span class="grid size-14 place-items-center rounded-2xl bg-primary/10 text-primary transition-transform duration-200 group-hover:-translate-y-0.5 group-hover:scale-105">
              <.icon name="hero-arrow-up-tray" class="size-6" />
            </span>
            <span class="text-base font-semibold tracking-tight">
              Drop your file here, or
              <span class="text-primary underline-offset-2 group-hover:underline">browse</span>
            </span>
            <span class="text-sm text-base-content/60">
              CSV or Excel (.xlsx), up to {div(@upload.max_file_size, 1_000_000)} MB and {delimit(
                @max_rows
              )} clients
            </span>
            <span class="mt-1 flex flex-wrap justify-center gap-1.5">
              <span
                :for={ext <- ~w(CSV XLSX TXT)}
                class="rounded-md border border-base-300 bg-base-100 px-2 py-0.5 text-2xs font-semibold tracking-wide text-base-content/60"
              >
                {ext}
              </span>
            </span>
            <.live_file_input upload={@upload} class="sr-only" />
          </label>
        </form>

        <div :for={entry <- @upload.entries} id={"import-entry-#{entry.ref}"} class="mt-4">
          <div class="flex items-center gap-3 rounded-box border border-base-300 px-3 py-2.5">
            <.icon name="hero-document-text" class="size-5 shrink-0 text-base-content/50" />
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium">{entry.client_name}</p>
              <div class="mt-1.5 h-1.5 overflow-hidden rounded-full bg-base-200">
                <div
                  class="h-full rounded-full bg-primary transition-[width] duration-300"
                  style={"width: #{entry.progress}%"}
                />
              </div>
              <p
                :for={error <- upload_errors(@upload, entry)}
                class="mt-1.5 text-xs text-error"
              >
                {upload_error(error)}
              </p>
            </div>
            <button
              type="button"
              phx-click="cancel-upload"
              phx-value-ref={entry.ref}
              class="btn btn-ghost btn-xs btn-square"
              aria-label="Remove file"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <p :for={error <- upload_errors(@upload)} class="mt-3 text-sm text-error">
          {upload_error(error)}
        </p>

        <div
          :if={@parse_error}
          id="import-parse-error"
          role="alert"
          class="mt-4 flex gap-3 rounded-box border border-error/30 bg-error/8 px-4 py-3 text-sm"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-error" />
          <div>
            <p class="font-medium">{@file_name} couldn't be read</p>
            <p class="mt-0.5 text-base-content/70">{@parse_error}</p>
          </div>
        </div>
      </section>

      <aside class="space-y-4">
        <section class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="text-sm font-semibold tracking-tight">Getting your file ready</h2>
          <ol class="mt-3 space-y-3 text-sm text-base-content/70">
            <li class="flex gap-2.5">
              <span class="grid size-5 shrink-0 place-items-center rounded-full bg-base-200 text-2xs font-semibold">1</span>
              <span>
                Export your customers or parties from
                <span class="text-base-content">{Enum.join(@sources, ", ")}</span>
                as CSV or Excel.
              </span>
            </li>
            <li class="flex gap-2.5">
              <span class="grid size-5 shrink-0 place-items-center rounded-full bg-base-200 text-2xs font-semibold">2</span>
              <span>Keep the column names in the first row. You'll match them to client fields next.</span>
            </li>
            <li class="flex gap-2.5">
              <span class="grid size-5 shrink-0 place-items-center rounded-full bg-base-200 text-2xs font-semibold">3</span>
              <span>Clients you already have are skipped, so it's safe to import the same list again.</span>
            </li>
          </ol>
        </section>

        <section class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="text-sm font-semibold tracking-tight">Every client needs</h2>
          <ul id="import-required" class="mt-2.5 flex flex-wrap gap-1.5">
            <li
              :for={label <- @required_labels}
              class="rounded-full bg-base-200 px-2.5 py-0.5 text-xs text-base-content/75"
            >
              {label}
            </li>
          </ul>
          <a
            id="import-template"
            href={~p"/clients/import/template.csv"}
            class="mt-4 inline-flex items-center gap-1.5 text-sm font-medium text-primary transition-colors hover:text-primary/80"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Download a template
          </a>
        </section>
      </aside>
    </div>
    """
  end

  # 2000 => "2,000"
  defp delimit(number) do
    number
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp upload_error(:too_large), do: "The file is larger than 5 MB."
  defp upload_error(:not_accepted), do: "Upload a CSV or an Excel (.xlsx) file."
  defp upload_error(:too_many_files), do: "Upload one file at a time."
  defp upload_error(:external_client_failure), do: "The upload failed. Try again."
  defp upload_error(_other), do: "That file couldn't be uploaded."

  # ── Step 2 ─────────────────────────────────────────────────────────────────

  attr :file_name, :string, required: true
  attr :headers, :list, required: true
  attr :row_count, :integer, required: true
  attr :samples, :map, required: true
  attr :mapping, :map, required: true
  attr :mapping_form, :any, required: true
  attr :mapping_errors, :list, required: true
  attr :field_options, :list, required: true
  attr :required, :list, required: true
  attr :definitions, :list, required: true

  defp mapping_step(assigns) do
    mapped = assigns.mapping |> Map.values() |> MapSet.new()
    assigns = assign(assigns, :mapped, mapped)

    ~H"""
    <.form
      for={@mapping_form}
      id="import-mapping-form"
      phx-change="map"
      phx-submit="review"
      class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem]"
    >
      <section class="overflow-hidden rounded-box border border-base-300 bg-base-100">
        <div class="flex flex-wrap items-center justify-between gap-2 border-b border-base-300 px-4 py-3">
          <div class="flex min-w-0 items-center gap-2.5">
            <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-success/12 text-success">
              <.icon name="hero-document-check" class="size-4.5" />
            </span>
            <div class="min-w-0">
              <p id="import-file-name" class="truncate text-sm font-semibold">{@file_name}</p>
              <p class="text-xs text-base-content/60">
                {@row_count} {if @row_count == 1, do: "row", else: "rows"} · {length(@headers)} columns
              </p>
            </div>
          </div>
          <button
            type="button"
            id="import-change-file"
            phx-click="back"
            phx-value-to="upload"
            class="text-xs font-medium text-base-content/60 transition-colors hover:text-base-content"
          >
            Choose another file
          </button>
        </div>

        <div class="hidden grid-cols-[minmax(0,1fr)_1.25rem_minmax(0,1fr)] gap-3 border-b border-base-300 bg-base-200/40 px-4 py-2 text-2xs font-semibold uppercase tracking-wide text-base-content/50 sm:grid">
          <span>Column in your file</span>
          <span></span>
          <span>Client field</span>
        </div>

        <ul id="import-columns" class="divide-y divide-base-300">
          <li
            :for={{header, index} <- Enum.with_index(@headers)}
            id={"import-column-#{index}"}
            class="grid gap-2 px-4 py-3 transition-colors hover:bg-base-200/30 sm:grid-cols-[minmax(0,1fr)_1.25rem_minmax(0,1fr)] sm:items-center sm:gap-3 [&_.fieldset]:mb-0"
          >
            <div class="min-w-0">
              <p class="truncate text-sm font-medium">{header}</p>
              <p class="truncate text-xs text-base-content/55">
                <%= case Map.get(@samples, to_string(index), []) do %>
                  <% [] -> %>
                    <span class="italic">Empty column</span>
                  <% values -> %>
                    {Enum.join(values, " · ")}
                <% end %>
              </p>
            </div>
            <.icon
              name="hero-arrow-right"
              class={[
                "hidden size-4 sm:block",
                if(Map.get(@mapping, to_string(index), "") == "",
                  do: "text-base-content/25",
                  else: "text-primary"
                )
              ]}
            />
            <.input
              field={@mapping_form[to_string(index)]}
              type="select"
              prompt="Don't import"
              options={@field_options}
              class={[
                "select select-sm w-full",
                Map.get(@mapping, to_string(index), "") == "" && "text-base-content/50"
              ]}
            />
          </li>
        </ul>
      </section>

      <aside class="space-y-4 lg:sticky lg:top-4 lg:self-start">
        <section class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="text-sm font-semibold tracking-tight">Required fields</h2>
          <ul id="import-required-check" class="mt-3 space-y-2 text-sm">
            <li
              :for={target <- @required}
              id={"import-required-#{target}"}
              class="flex items-center gap-2"
            >
              <%= if MapSet.member?(@mapped, target) do %>
                <.icon name="hero-check-circle-solid" class="size-4.5 text-success" />
                <span>{Import.label(target, @definitions)}</span>
              <% else %>
                <.icon name="hero-minus-circle" class="size-4.5 text-base-content/30" />
                <span class="text-base-content/60">{Import.label(target, @definitions)}</span>
              <% end %>
            </li>
          </ul>

          <div
            :if={@mapping_errors != []}
            id="import-mapping-errors"
            role="alert"
            class="mt-4 space-y-1 rounded-lg bg-error/8 px-3 py-2.5 text-xs text-error"
          >
            <p :for={message <- @mapping_errors}>{message}</p>
          </div>

          <button
            id="import-to-review"
            type="submit"
            class={[action_button_class(), "mt-4 w-full justify-center"]}
            phx-disable-with="Checking rows…"
          >
            Check {@row_count} {if @row_count == 1, do: "row", else: "rows"}
            <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </section>

        <p class="px-1 text-xs leading-relaxed text-base-content/55">
          Columns were matched by their names. Change any that are wrong, and leave the rest as
          “Don't import”.
        </p>
      </aside>
    </.form>
    """
  end

  # ── Step 3 ─────────────────────────────────────────────────────────────────

  attr :file_name, :string, required: true
  attr :counts, :map, required: true
  attr :filter, :string, required: true
  attr :shown, :integer, required: true
  attr :streams, :any, required: true
  attr :regime, :string, required: true

  defp review_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <div id="import-summary" class="grid gap-3 sm:grid-cols-3">
        <.summary_tile
          id="import-count-ready"
          icon="hero-check-circle"
          tone="bg-success/12 text-success"
          count={@counts.ready}
          label="Ready to import"
        />
        <.summary_tile
          id="import-count-invalid"
          icon="hero-exclamation-triangle"
          tone="bg-warning/15 text-warning"
          count={@counts.invalid}
          label="Need fixing (skipped)"
        />
        <.summary_tile
          id="import-count-duplicate"
          icon="hero-document-duplicate"
          tone="bg-base-200 text-base-content/60"
          count={@counts.duplicate}
          label="Already exist (skipped)"
        />
      </div>

      <section class="overflow-hidden rounded-box border border-base-300 bg-base-100">
        <div class="flex flex-wrap items-center justify-between gap-2 border-b border-base-300 px-4 py-2.5">
          <div class="flex items-center gap-1" role="group" aria-label="Show rows">
            <button
              :for={{key, label} <- [{"all", "All rows"}, {"problems", "Skipped only"}]}
              id={"import-filter-#{key}"}
              type="button"
              phx-click="filter"
              phx-value-filter={key}
              aria-pressed={to_string(@filter == key)}
              class={[
                "rounded-lg px-2.5 py-1 text-xs font-medium transition-colors duration-150",
                if(@filter == key,
                  do: "bg-base-200 text-base-content",
                  else: "text-base-content/60 hover:bg-base-200/60 hover:text-base-content"
                )
              ]}
            >
              {label}
            </button>
          </div>
          <p class="text-xs text-base-content/55">
            Rows are numbered as in {@file_name}.
          </p>
        </div>

        <div class="max-h-128 overflow-auto">
          <table class="table table-sm">
            <thead class="sticky top-0 z-10 bg-base-100">
              <tr class="text-2xs uppercase tracking-wide text-base-content/50">
                <th class="w-14">Row</th>
                <th>Client</th>
                <th class="hidden md:table-cell">Phone</th>
                <th class="hidden md:table-cell">
                  {if @regime == "vat", do: "Tax number", else: "GSTIN"}
                </th>
                <th class="w-40">Status</th>
              </tr>
            </thead>
            <tbody id="import-rows" phx-update="stream">
              <tr id="import-rows-empty" class="hidden only:table-row">
                <td colspan="5" class="py-8 text-center text-sm text-base-content/55">
                  Nothing was skipped.
                </td>
              </tr>
              <tr
                :for={{id, row} <- @streams.rows}
                id={id}
                class="align-top transition-colors hover:bg-base-200/30"
              >
                <td class="tabular-nums text-base-content/55">{row.row}</td>
                <td class="max-w-0">
                  <p class="truncate font-medium">
                    {if row.name == "", do: "(no name)", else: row.name}
                  </p>
                  <ul :if={row.errors != []} class="mt-1 space-y-0.5">
                    <li
                      :for={error <- row.errors}
                      class={[
                        "text-xs",
                        if(row.status == :invalid, do: "text-error", else: "text-base-content/60")
                      ]}
                    >
                      {error}
                    </li>
                  </ul>
                </td>
                <td class="hidden whitespace-nowrap text-base-content/70 md:table-cell">
                  {row.phone}
                </td>
                <td class="hidden font-mono text-xs text-base-content/70 md:table-cell">
                  {if @regime == "vat", do: row.attrs["tax_number"], else: row.attrs["gstin"]}
                </td>
                <td><.row_status status={row.status} /></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <div class="flex flex-col-reverse gap-2 sm:flex-row sm:items-center sm:justify-between">
        <button
          id="import-back"
          type="button"
          phx-click="back"
          phx-value-to="mapping"
          class={secondary_button_class()}
        >
          <.icon name="hero-arrow-left" class="size-4" /> Back to columns
        </button>

        <button
          id="import-submit"
          type="button"
          phx-click="import"
          disabled={@counts.ready == 0}
          phx-disable-with="Importing…"
          class={[
            action_button_class(),
            "justify-center disabled:cursor-not-allowed disabled:opacity-50"
          ]}
        >
          <.icon name="hero-arrow-down-on-square-stack" class="size-4" />
          Import {@counts.ready} {if @counts.ready == 1, do: "client", else: "clients"}
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :tone, :string, required: true
  attr :count, :integer, required: true
  attr :label, :string, required: true

  defp summary_tile(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex items-center gap-3 rounded-box border border-base-300 bg-base-100 px-4 py-3.5 transition-shadow duration-200 hover:shadow-sm"
    >
      <span class={["grid size-10 shrink-0 place-items-center rounded-xl", @tone]}>
        <.icon name={@icon} class="size-5" />
      </span>
      <div>
        <p class="text-xl font-semibold tabular-nums tracking-tight">{@count}</p>
        <p class="text-xs text-base-content/60">{@label}</p>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp row_status(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium",
      @status == :ready && "bg-success/12 text-success",
      @status == :invalid && "bg-warning/15 text-warning",
      @status == :duplicate && "bg-base-200 text-base-content/60"
    ]}>
      <%= case @status do %>
        <% :ready -> %>
          <.icon name="hero-check" class="size-3.5" /> Ready
        <% :invalid -> %>
          <.icon name="hero-exclamation-triangle" class="size-3.5" /> Needs fixing
        <% :duplicate -> %>
          <.icon name="hero-document-duplicate" class="size-3.5" /> Already exists
      <% end %>
    </span>
    """
  end

  # ── Done ───────────────────────────────────────────────────────────────────

  attr :imported, :integer, required: true
  attr :counts, :map, required: true

  defp done_step(assigns) do
    assigns = assign(assigns, :skipped, assigns.counts.invalid + assigns.counts.duplicate)

    ~H"""
    <section
      id="import-done"
      class="mx-auto max-w-lg rounded-box border border-base-300 bg-base-100 px-6 py-10 text-center"
    >
      <span class="mx-auto grid size-14 place-items-center rounded-full bg-success/12 text-success">
        <.icon name="hero-check-circle" class="size-8" />
      </span>
      <h2 class="mt-4 text-lg font-semibold tracking-tight">
        {@imported} {if @imported == 1, do: "client", else: "clients"} imported
      </h2>
      <p class="mt-1 text-sm text-base-content/60">
        <%= if @skipped == 0 do %>
          Every row in the file was added.
        <% else %>
          {@skipped} {if @skipped == 1, do: "row was", else: "rows were"} skipped. Fix them in the file and import it again; clients already added will be skipped.
        <% end %>
      </p>
      <div class="mt-6 flex flex-wrap justify-center gap-2">
        <.link id="import-view-clients" navigate={~p"/clients"} class={action_button_class()}>
          <.icon name="hero-users" class="size-4" /> View clients
        </.link>
        <button id="import-again" type="button" phx-click="restart" class={secondary_button_class()}>
          <.icon name="hero-arrow-up-tray" class="size-4" /> Import another file
        </button>
      </div>
    </section>
    """
  end
end
