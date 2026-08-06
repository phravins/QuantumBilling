defmodule QuantumBillingWeb.InvoiceTemplateDesignLive do
  @moduledoc """
  The invoice design pad.

  Three columns: the palette of blocks that can be added, the canvas showing the
  document as it will print, and the inspector for whichever block is selected.

  ## The document in memory is the source of truth

  The layout XML is parsed once on mount and serialised once per save. It is
  never round-tripped per keystroke, because that would make every edit depend on
  serialiser fidelity — a bug there would silently eat a user's work mid-session
  rather than failing where it could be seen.

  ## Every change saves

  There is no Save button. Templates are small and saves are cheap, and autosave
  removes the entire class of "I dragged six blocks and then navigated away"
  problems. The header shows when the last save landed.

  ## Blocks are addressed by id, and ids come from the server

  Every event names a block id, and every handler ignores an id the document does
  not have. A pad left open in another tab can therefore not resurrect a block
  that has since been removed.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.InvoiceTemplateComponents

  alias QuantumBilling.Settings
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoiceDoc.Renderer
  alias QuantumBillingWeb.InvoiceDocument

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Templates.get_template(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That template does not exist.")
         |> push_navigate(to: ~p"/settings/customization")}

      template ->
        organization = Settings.get_organization()

        {:ok,
         socket
         |> assign(:page_title, template.name)
         |> assign(:active_nav, :settings)
         |> assign(:active_sub, :customization)
         |> assign(:template, template)
         |> assign(:doc, Templates.document_of(template))
         |> assign(:selected_id, nil)
         |> assign(:saved_at, nil)
         |> assign(:error, nil)
         |> assign(:sample, InvoiceDocument.sample())
         |> assign(:logo, presence(organization.doc_logo_path))
         |> assign(:form, to_form(%{"name" => template.name, "accent" => template.accent}))}
    end
  end

  # ── Blocks ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("add_block", %{"type" => type}, socket) do
    doc = socket.assigns.doc

    case block_type(type) do
      nil ->
        {:noreply, socket}

      type ->
        if Catalog.singleton?(type) and Document.has_type?(doc, type) do
          {:noreply, socket}
        else
          block = Catalog.new(type, Document.next_id(doc))
          doc = %{doc | blocks: doc.blocks ++ [block]}

          {:noreply, socket |> assign(:selected_id, block.id) |> save(doc)}
        end
    end
  end

  def handle_event("remove_block", %{"id" => id}, socket) do
    doc = socket.assigns.doc

    case Document.block(doc, id) do
      nil ->
        {:noreply, socket}

      block ->
        if Catalog.required?(block.type) do
          {:noreply,
           put_flash(
             socket,
             :error,
             "An invoice needs its #{label_for(block.type)}, so that block cannot be removed."
           )}
        else
          doc = %{doc | blocks: Enum.reject(doc.blocks, &(&1.id == id))}

          selected =
            if socket.assigns.selected_id == id, do: nil, else: socket.assigns.selected_id

          {:noreply, socket |> assign(:selected_id, selected) |> save(doc)}
        end
    end
  end

  def handle_event("move_block", %{"id" => id, "dir" => dir}, socket) do
    doc = socket.assigns.doc
    ids = Document.ids(doc)
    index = Enum.find_index(ids, &(&1 == id))

    case swap(ids, index, dir) do
      nil -> {:noreply, socket}
      reordered -> {:noreply, save(socket, reorder(doc, reordered))}
    end
  end

  @doc """
  Reorders from the drag hook.

  The incoming list is accepted only when it is an exact permutation of the ids
  the server currently holds. A stale client — one whose page was rendered before
  a block was added or removed — would otherwise be able to delete blocks by
  omitting them from a drop.
  """
  def handle_event("reorder_blocks", %{"ids" => ids}, socket) when is_list(ids) do
    current = Document.ids(socket.assigns.doc)

    if Enum.sort(ids) == Enum.sort(current) do
      {:noreply, save(socket, reorder(socket.assigns.doc, ids))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_block", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_id, id)}
  end

  def handle_event("update_block", %{"_id" => id} = params, socket) do
    doc = socket.assigns.doc

    case Document.block(doc, id) do
      nil ->
        {:noreply, socket}

      block ->
        # Through the catalogue's whitelist, never straight onto the struct: an
        # injected param cannot set an option this block does not have.
        {:noreply, save(socket, Document.put_block(doc, Catalog.cast_block(block, params)))}
    end
  end

  # ── Columns and total lines ───────────────────────────────────────────────

  def handle_event("toggle_child", %{"field" => field}, socket) do
    with_selected(socket, fn doc, block ->
      cond do
        Enum.any?(block.children, &(&1.field == field)) ->
          if block.type == :items and Catalog.required_item_field?(field) do
            :error
          else
            children = Enum.reject(block.children, &(&1.field == field))
            {:ok, Document.put_block(doc, %{block | children: children})}
          end

        child = Catalog.new_child(block.type, field) ->
          {:ok, Document.put_block(doc, %{block | children: block.children ++ [child]})}

        true ->
          :error
      end
    end)
  end

  def handle_event("move_child", %{"field" => field, "dir" => dir}, socket) do
    with_selected(socket, fn doc, block ->
      fields = Enum.map(block.children, & &1.field)
      index = Enum.find_index(fields, &(&1 == field))

      case swap(fields, index, dir) do
        nil ->
          :error

        reordered ->
          children = Enum.map(reordered, fn f -> Enum.find(block.children, &(&1.field == f)) end)
          {:ok, Document.put_block(doc, %{block | children: children})}
      end
    end)
  end

  # ── Page and template ─────────────────────────────────────────────────────

  def handle_event("update_page", %{"page" => params}, socket) do
    doc = socket.assigns.doc

    page =
      Enum.reduce(Layout.page_attrs(), doc.page, fn {xml, key, kind, _default}, acc ->
        case Map.fetch(params, xml) do
          {:ok, raw} ->
            case Catalog.cast_value(raw, kind) do
              {:ok, value} -> Map.put(acc, key, value)
              :error -> acc
            end

          :error ->
            acc
        end
      end)

    {:noreply, save(socket, %{doc | page: page})}
  end

  def handle_event("update_template", params, socket) do
    attrs = Map.take(params, ["name", "accent"])

    case Templates.update_template(socket.assigns.template, attrs) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:template, template)
         |> assign(:page_title, template.name)
         |> assign(:error, nil)
         |> mark_saved()}

      {:error, changeset} ->
        {:noreply, assign(socket, :error, first_error(changeset))}
    end
  end

  def handle_event("set_default", _params, socket) do
    case Templates.set_default(socket.assigns.template) do
      {:ok, template} ->
        {:noreply, socket |> assign(:template, template) |> mark_saved()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That could not be made default.")}
    end
  end

  def handle_event("reset_layout", _params, socket) do
    {:noreply, socket |> assign(:selected_id, nil) |> save(Catalog.classic())}
  end

  # ── Saving ────────────────────────────────────────────────────────────────

  # Every mutation lands here. The document in memory is updated either way, so a
  # rejected save leaves the canvas showing what the user did rather than
  # silently reverting it; the message says what is wrong.
  defp save(socket, doc) do
    socket = assign(socket, :doc, doc)

    case Templates.update_template(socket.assigns.template, %{"layout_xml" => Layout.to_xml(doc)}) do
      {:ok, template} ->
        socket |> assign(:template, template) |> assign(:error, nil) |> mark_saved()

      {:error, changeset} ->
        assign(socket, :error, first_error(changeset))
    end
  end

  defp mark_saved(socket), do: assign(socket, :saved_at, Time.utc_now())

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {_field, messages} -> List.wrap(messages) end)
    |> List.first()
  end

  # Applies `fun` to the selected block, saving when it returns a document.
  defp with_selected(socket, fun) do
    doc = socket.assigns.doc

    case Document.block(doc, socket.assigns.selected_id) do
      nil ->
        {:noreply, socket}

      block ->
        case fun.(doc, block) do
          {:ok, doc} -> {:noreply, save(socket, doc)}
          :error -> {:noreply, socket}
        end
    end
  end

  defp reorder(doc, ids) do
    %{doc | blocks: Enum.map(ids, fn id -> Document.block(doc, id) end)}
  end

  defp swap(_list, nil, _dir), do: nil
  defp swap(_list, 0, "up"), do: nil

  defp swap(list, index, "up") do
    List.replace_at(list, index, Enum.at(list, index - 1))
    |> List.replace_at(index - 1, Enum.at(list, index))
  end

  defp swap(list, index, "down") when index >= 0 do
    if index == length(list) - 1 do
      nil
    else
      List.replace_at(list, index, Enum.at(list, index + 1))
      |> List.replace_at(index + 1, Enum.at(list, index))
    end
  end

  defp swap(_list, _index, _dir), do: nil

  # Never `String.to_atom/1` on a param. The palette is a closed list.
  defp block_type(value) do
    Enum.find(Catalog.types(), fn type -> to_string(type) == value end)
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:selected, Document.block(assigns.doc, assigns.selected_id))
      |> assign(:count, length(assigns.doc.blocks))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      active_sub={@active_sub}
    >
      <nav class="mb-2 flex items-center gap-1.5 text-xs text-base-content/45" aria-label="Breadcrumb">
        <.link navigate={~p"/settings/customization"} class="hover:text-base-content">
          Invoice Customization
        </.link>
        <.icon name="hero-chevron-right" class="size-3" />
        <span class="text-base-content/60">{@template.name}</span>
      </nav>

      <.header>
        <form
          id="template-name-form"
          phx-change="update_template"
          phx-submit="update_template"
          class="contents"
        >
          <input
            type="text"
            name="name"
            value={@template.name}
            aria-label="Template name"
            class="w-full max-w-sm rounded-field border border-transparent bg-transparent px-1 py-0.5 text-xl font-semibold tracking-tight hover:border-base-300 focus:border-base-300 focus:outline-none focus:ring-2 focus:ring-base-content/10"
          />
        </form>

        <:subtitle>
          <span :if={@error} class="text-red-600">{@error}</span>
          <span :if={is_nil(@error) and @saved_at} class="text-base-content/45">Saved</span>
          <span :if={is_nil(@error) and is_nil(@saved_at)}>
            {@count} blocks · changes save as you make them
          </span>
        </:subtitle>

        <:actions>
          <div class="flex items-center gap-2">
            <form
              id="template-accent-form"
              phx-change="update_template"
              class="flex items-center gap-1.5"
            >
              <label for="template-accent" class="text-xs text-base-content/60">Accent</label>
              <input
                type="color"
                id="template-accent"
                name="accent"
                value={@template.accent}
                class="size-8 cursor-pointer rounded-field border border-base-300 bg-base-100 p-0.5"
              />
            </form>

            <button
              :if={!@template.is_default}
              type="button"
              phx-click="set_default"
              class={secondary_button_class()}
            >
              Make default
            </button>
            <span
              :if={@template.is_default}
              class="inline-flex h-9 items-center rounded-field bg-base-200 px-3 text-sm text-base-content/70"
            >
              Default
            </span>

            <.link navigate={~p"/settings/customization"} class={secondary_button_class()}>
              Done
            </.link>
          </div>
        </:actions>
      </.header>

      <div class="flex flex-1 gap-3">
        <%!-- Palette --%>
        <.card padding="p-2" class="hidden w-44 shrink-0 self-start lg:block">
          <.block_palette doc={@doc} />

          <div class="mt-3 space-y-2 border-t border-base-300 pt-3">
            <p class="px-1 text-2xs font-medium uppercase tracking-wider text-base-content/45">
              Page
            </p>
            <form id="template-page-form" phx-change="update_page" class="space-y-2 px-1">
              <label class="block">
                <span class="mb-1 block text-xs text-base-content/60">Margin</span>
                <select
                  name="page[margin]"
                  class="w-full rounded-field border border-base-300 bg-base-100 px-2 py-1 text-xs"
                >
                  <option
                    :for={v <- ~w(10mm 14mm 18mm 22mm)}
                    value={v}
                    selected={v == @doc.page.margin}
                  >
                    {v}
                  </option>
                </select>
              </label>
              <label class="block">
                <span class="mb-1 block text-xs text-base-content/60">Text size</span>
                <select
                  name="page[base-font]"
                  class="w-full rounded-field border border-base-300 bg-base-100 px-2 py-1 text-xs"
                >
                  <option :for={v <- 10..14} value={v} selected={v == @doc.page.base_font}>
                    {v}px
                  </option>
                </select>
              </label>
              <label class="block">
                <span class="mb-1 block text-xs text-base-content/60">Typeface</span>
                <select
                  name="page[font]"
                  class="w-full rounded-field border border-base-300 bg-base-100 px-2 py-1 text-xs"
                >
                  <option :for={v <- ~w(sans serif)} value={v} selected={v == @doc.page.font}>
                    {v}
                  </option>
                </select>
              </label>
            </form>

            <button
              type="button"
              phx-click="reset_layout"
              data-confirm="Reset this template to the standard layout? Your changes to it will be lost."
              class="w-full rounded-field px-1 py-1 text-left text-xs text-base-content/45 hover:text-red-600"
            >
              Reset to standard
            </button>
          </div>
        </.card>

        <%!-- Canvas --%>
        <.card padding="p-6" class="min-w-0 flex-1">
          <Renderer.stylesheet doc={@doc} />

          <%!-- The hook listens on this container and delegates, rather than
          binding every card, so blocks added later need no rebinding. It pushes
          an id order and leaves the DOM alone: the server's re-render is the
          only thing that moves anything, which is why `phx-update="ignore"`
          would be wrong here — it would freeze the list against the pad's own
          add and move events. --%>
          <div id="canvas-blocks" phx-hook=".BlockSort" class="mx-auto max-w-[800px] space-y-1">
            <.canvas_block
              :for={{block, index} <- Enum.with_index(@doc.blocks)}
              block={block}
              doc={@doc}
              invoice={@sample}
              logo={@logo}
              accent={@template.accent}
              selected={block.id == @selected_id}
              first={index == 0}
              last={index == @count - 1}
            />
          </div>

          <p :if={@count == 0} class="py-10 text-center text-sm text-base-content/45">
            This template is empty. Add a block from the left to begin.
          </p>
        </.card>

        <%!-- Inspector --%>
        <.card padding="p-3" class="hidden w-72 shrink-0 self-start xl:block">
          <.inspector block={@selected} page={@doc.page} />
        </.card>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BlockSort">
        // Reorders canvas blocks by dragging. The up/down buttons are the
        // primary path -- they work from the keyboard, which this does not --
        // so this is an accelerator and is allowed to be simple.
        //
        // Deliberately does NOT reorder the DOM. It computes the order the drop
        // implies and pushes it; the server re-renders, and the server's order
        // is the only one that gets saved. That is what keeps the DOM and the
        // document from ever disagreeing.
        export default {
          mounted() {
            this.dragId = null

            this.el.addEventListener("dragstart", (e) => {
              const card = e.target.closest("[data-block-id]")
              if (!card) return
              this.dragId = card.dataset.blockId
              card.classList.add("opacity-40")
              e.dataTransfer.effectAllowed = "move"
              // Firefox refuses to start a drag with nothing on the transfer.
              e.dataTransfer.setData("text/plain", this.dragId)
            })

            this.el.addEventListener("dragover", (e) => {
              e.preventDefault()
              e.dataTransfer.dropEffect = "move"
            })

            this.el.addEventListener("drop", (e) => {
              e.preventDefault()
              const over = e.target.closest("[data-block-id]")
              if (!over || !this.dragId || over.dataset.blockId === this.dragId) return

              const ids = [...this.el.querySelectorAll("[data-block-id]")]
                .map((n) => n.dataset.blockId)
                .filter((id) => id !== this.dragId)

              const at = ids.indexOf(over.dataset.blockId)
              // Dropping on the lower half of a card lands after it.
              const box = over.getBoundingClientRect()
              const after = e.clientY > box.top + box.height / 2
              ids.splice(after ? at + 1 : at, 0, this.dragId)

              this.pushEvent("reorder_blocks", {ids})
            })

            this.el.addEventListener("dragend", () => {
              this.dragId = null
              this.el
                .querySelectorAll(".opacity-40")
                .forEach((n) => n.classList.remove("opacity-40"))
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
